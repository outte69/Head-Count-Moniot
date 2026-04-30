#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "json"
require "csv"
require "net/http"
require "securerandom"
require "time"
require "digest"
require "uri"
require "sqlite3"

module VisitorIslandMonitor
  class Error < StandardError
    attr_reader :status

    def initialize(message, status: 400)
      super(message)
      @status = status
    end
  end

  class Store
    def initialize(database_path, table_name)
      @database_path = database_path
      @table_name = table_name
      ensure_database
    end

    def read_records
      database.execute("SELECT payload FROM #{@table_name} ORDER BY row_order ASC").map do |row|
        JSON.parse(row[0])
      end
    end

    def write_records(records)
      database.transaction
      database.execute("DELETE FROM #{@table_name}")
      records.each_with_index do |record, index|
        database.execute(
          "INSERT INTO #{@table_name} (row_order, payload) VALUES (?, ?)",
          index,
          JSON.generate(record)
        )
      end
      database.commit
    rescue StandardError
      database.rollback
      raise
    end

    def import_json_file(json_path)
      return unless File.exist?(json_path)
      return unless read_records.empty?

      payload = JSON.parse(File.read(json_path))
      write_records(payload) if payload.is_a?(Array)
    end

    private

    def ensure_database
      ensure_parent_dir
      database.execute <<~SQL
        CREATE TABLE IF NOT EXISTS #{@table_name} (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          row_order INTEGER NOT NULL,
          payload TEXT NOT NULL
        )
      SQL
    end

    def ensure_parent_dir
      Dir.mkdir(File.dirname(@database_path)) unless Dir.exist?(File.dirname(@database_path))
    end

    def database
      @database ||= begin
        db = SQLite3::Database.new(@database_path)
        db.busy_timeout = 5000
        db
      end
    end
  end

  class UserStore < Store
    DEFAULT_ADMIN_USERNAME = "Supervisor"
    DEFAULT_ADMIN_PASSWORD = "Cross@119"

    def initialize(database_path)
      super(database_path, "users")
    end

    alias read_users read_records
    alias write_users write_records

    def ensure_default_admin
      return unless read_users.empty?

      salt = SecureRandom.hex(16)
      write_records([
        {
          "username" => DEFAULT_ADMIN_USERNAME,
          "role" => "admin",
          "passwordSalt" => salt,
          "passwordHash" => self.class.password_hash(DEFAULT_ADMIN_PASSWORD, salt),
          "createdAt" => Time.now.utc.iso8601
        }
      ])
    end

    private

    def self.password_hash(password, salt)
      Digest::SHA256.hexdigest("#{salt}::#{password}")
    end
  end

  class JsonStateFile
    def initialize(path)
      @path = path
      ensure_parent_dir
    end

    def fetch(key)
      read_state[key]
    end

    def write(key, value)
      state = read_state
      state[key] = value
      File.write(@path, JSON.pretty_generate(state))
    end

    private

    def ensure_parent_dir
      dir = File.dirname(@path)
      Dir.mkdir(dir) unless Dir.exist?(dir)
    end

    def read_state
      return {} unless File.exist?(@path)

      JSON.parse(File.read(@path))
    rescue JSON::ParserError
      {}
    end
  end

  class App
    def initialize(public_dir:, data_file:)
      @public_dir = public_dir
      app_dir = File.dirname(data_file)
      database_path = ENV["DATABASE_PATH"] || File.join(app_dir, "visitor_island_monitor.sqlite3")
      @store = Store.new(database_path, "records")
      @user_store = UserStore.new(database_path)
      @audit_store = Store.new(database_path, "audit_logs")
      @whatsapp_store = Store.new(database_path, "whatsapp_recipients")
      @state_store = JsonStateFile.new(File.join(File.dirname(database_path), "visitor_monitor_state.json"))
      import_legacy_json(app_dir)
      @user_store.ensure_default_admin
      @sessions = {}
      start_whatsapp_scheduler
    end

    def handle_request(method:, path:, body: nil, env: {})
      route_api(method, path, body, env)
    rescue Error => error
      json_response(error.status, { error: error.message })
    rescue StandardError => error
      warn "[visitor-island-monitor] #{error.class}: #{error.message}"
      json_response(500, { error: "Server error" })
    end

    def call(env)
      method = env["REQUEST_METHOD"].to_s.upcase
      path = env["PATH_INFO"].to_s

      if path.start_with?("/api/")
        body = env["rack.input"]&.read.to_s
        status, headers, response_body = handle_request(method: method, path: path, body: body, env: env)
        return [status, headers, [response_body]]
      end

      serve_static(path)
    rescue StandardError => error
      warn "[visitor-island-monitor] #{error.class}: #{error.message}"
      [500, { "Content-Type" => "text/plain; charset=utf-8" }, ["Server error"]]
    end

    private

    def route_api(method, path, body, env)
      return json_response(200, { status: "ok", app: "visitor-island-monitor" }) if method == "GET" && path == "/api/health"
      return session_status(env) if method == "GET" && path == "/api/session"
      return login(body) if method == "POST" && path == "/api/login"
      return logout(env) if method == "POST" && path == "/api/logout"

      current_user = current_user_from_env(env)

      if path == "/api/records"
        require_user!(current_user)
        return list_records if method == "GET"
        return create_record(body) if method == "POST"

        raise Error.new("Method not allowed", status: 405)
      end

      if path.start_with?("/api/record/")
        require_user!(current_user)
        id = path.split("/").last
        raise Error.new("Missing record id", status: 400) if id.to_s.strip.empty?

        return update_record(id, body) if method == "PUT"
        return delete_record(id, current_user) if method == "DELETE"

        raise Error.new("Method not allowed", status: 405)
      end

      if path == "/api/users"
        require_admin!(current_user)
        return list_users if method == "GET"
        return create_user(body, current_user) if method == "POST"

        raise Error.new("Method not allowed", status: 405)
      end

      if path.start_with?("/api/user/")
        require_admin!(current_user)
        username = path.split("/", 4).last.to_s
        raise Error.new("Missing username", status: 400) if username.strip.empty?

        return update_user(username, body, current_user) if method == "PUT"

        raise Error.new("Method not allowed", status: 405)
      end

      if path == "/api/audit-log"
        require_admin!(current_user)
        return list_audit_log if method == "GET"

        raise Error.new("Method not allowed", status: 405)
      end

      if path == "/api/reports/summary"
        require_user!(current_user)
        return report_summary(body) if method == "POST"

        raise Error.new("Method not allowed", status: 405)
      end

      if path == "/api/admin/export"
        require_admin!(current_user)
        return export_records(body) if method == "POST"

        raise Error.new("Method not allowed", status: 405)
      end

      if path == "/api/admin/import-records"
        require_admin!(current_user)
        return import_records(body, current_user) if method == "POST"

        raise Error.new("Method not allowed", status: 405)
      end

      if path == "/api/admin/import-users"
        require_admin!(current_user)
        return import_users(body, current_user) if method == "POST"

        raise Error.new("Method not allowed", status: 405)
      end

      if path == "/api/admin/whatsapp-recipients"
        require_admin!(current_user)
        return list_whatsapp_recipients if method == "GET"
        return create_whatsapp_recipient(body, current_user) if method == "POST"

        raise Error.new("Method not allowed", status: 405)
      end

      if path == "/api/admin/whatsapp-status"
        require_admin!(current_user)
        return whatsapp_status if method == "GET"

        raise Error.new("Method not allowed", status: 405)
      end

      if path == "/api/admin/whatsapp-send-test"
        require_admin!(current_user)
        return send_test_whatsapp(body, current_user) if method == "POST"

        raise Error.new("Method not allowed", status: 405)
      end

      if path.start_with?("/api/admin/whatsapp-recipient/")
        require_admin!(current_user)
        id = path.split("/").last
        raise Error.new("Missing WhatsApp recipient id", status: 400) if id.to_s.strip.empty?

        return update_whatsapp_recipient(id, body, current_user) if method == "PUT"
        return delete_whatsapp_recipient(id, current_user) if method == "DELETE"

        raise Error.new("Method not allowed", status: 405)
      end

      if path == "/api/admin/backup-export"
        require_backup_token!(env)
        return backup_export(body) if method == "POST"

        raise Error.new("Method not allowed", status: 405)
      end

      raise Error.new("Not found", status: 404)
    end

    def list_records
      records = @store.read_records.sort_by { |record| [record["date"], record["time"]] }.reverse
      json_response(200, records)
    end

    def create_record(body)
      payload = parse_json_body(body)
      records = @store.read_records
      record = normalize_record(payload)
      records << record
      @store.write_records(records)
      log_event(
        event_type: "record_created",
        actor: payload["user"].to_s,
        target_type: "record",
        target_id: record["id"],
        details: record_summary(record)
      )
      json_response(201, record)
    end

    def update_record(id, body)
      payload = parse_json_body(body)
      records = @store.read_records
      index = records.index { |record| record["id"] == id }
      raise Error.new("Record not found", status: 404) unless index

      previous = records[index]
      record = normalize_record(payload, id)
      records[index] = record
      @store.write_records(records)
      log_event(
        event_type: "record_updated",
        actor: payload["user"].to_s,
        target_type: "record",
        target_id: record["id"],
        details: {
          "before" => record_summary(previous),
          "after" => record_summary(record)
        }
      )
      json_response(200, record)
    end

    def delete_record(id, current_user)
      require_admin!(current_user)
      records = @store.read_records
      index = records.index { |record| record["id"] == id }
      raise Error.new("Record not found", status: 404) unless index

      deleted = records.delete_at(index)
      @store.write_records(records)
      log_event(
        event_type: "record_deleted",
        actor: current_user["username"].to_s,
        target_type: "record",
        target_id: deleted["id"],
        details: record_summary(deleted)
      )
      json_response(200, deleted)
    end

    def parse_json_body(body)
      JSON.parse(body.to_s.strip.empty? ? "{}" : body.to_s)
    rescue JSON::ParserError
      raise Error.new("Request body must be valid JSON", status: 400)
    end

    def parse_cookies(cookie_header)
      cookie_header.to_s.split(";").each_with_object({}) do |pair, acc|
        key, value = pair.strip.split("=", 2)
        next if key.to_s.empty?

        acc[key] = value.to_s
      end
    end

    def current_user_from_env(env)
      token = parse_cookies(env["HTTP_COOKIE"])["visitor_monitor_session"]
      return nil if token.to_s.empty?

      @sessions[token]
    end

    def require_user!(current_user)
      raise Error.new("Please sign in to continue", status: 401) unless current_user
    end

    def require_admin!(current_user)
      require_user!(current_user)
      raise Error.new("Admin access is required", status: 403) unless current_user["role"] == "admin"
    end

    def require_backup_token!(env)
      expected = ENV["BACKUP_API_TOKEN"].to_s
      raise Error.new("Backup API token is not configured", status: 503) if expected.empty?

      provided = env["HTTP_X_BACKUP_TOKEN"].to_s
      raise Error.new("Backup token is required", status: 401) if provided.empty?
      raise Error.new("Invalid backup token", status: 403) unless provided == expected
    end

    def whatsapp_enabled?
      ENV["WHATSAPP_SUMMARY_ENABLED"].to_s == "true"
    end

    def whatsapp_ready?
      whatsapp_enabled? &&
        !ENV["WHATSAPP_ACCESS_TOKEN"].to_s.empty? &&
        !ENV["WHATSAPP_PHONE_NUMBER_ID"].to_s.empty? &&
        !ENV["WHATSAPP_TEMPLATE_NAME"].to_s.empty?
    end

    def whatsapp_named_recipients
      ENV.fetch("WHATSAPP_RECIPIENTS", "").split(",").map(&:strip).filter_map do |entry|
        name, number = entry.split(":", 2).map { |value| value.to_s.strip }
        next if name.empty? || number.empty?

        { "name" => name, "number" => number }
      end
    end

    def configured_whatsapp_recipients
      stored = @whatsapp_store.read_records
      return stored unless stored.empty?

      whatsapp_named_recipients
    end

    def start_whatsapp_scheduler
      return unless whatsapp_ready?
      return if defined?(@whatsapp_scheduler_started) && @whatsapp_scheduler_started

      @whatsapp_scheduler_started = true
      Thread.new do
        Thread.current.name = "visitor-monitor-whatsapp-summary" if Thread.current.respond_to?(:name=)
        loop do
          run_hourly_whatsapp_summary_if_due
          sleep 60
        rescue StandardError => error
          warn "[visitor-island-monitor] WhatsApp scheduler error: #{error.class}: #{error.message}"
          sleep 60
        end
      end
    end

    def run_hourly_whatsapp_summary_if_due
      recipients = configured_whatsapp_recipients
      return if recipients.empty?

      now = Time.now
      current_hour_key = now.strftime("%Y-%m-%d-%H")
      return if @state_store.fetch("lastWhatsappSummaryHour") == current_hour_key

      summary_date = operational_today
      records = sorted_records.select { |record| operational_date(record["date"], record["time"]) == summary_date }
      return if records.empty?

      totals = calculate_totals(records)
      recipients.each do |recipient|
        send_whatsapp_summary(recipient, summary_date, totals)
      end
      @state_store.write("lastWhatsappSummaryHour", current_hour_key)
      @state_store.write("lastWhatsappSentAt", Time.now.utc.iso8601)
      @state_store.write("lastWhatsappSendStatus", "success")
    end

    def whatsapp_summary_message(summary_date, totals)
      [
        "Visitor Island Monitor",
        "Duty Date: #{display_date(summary_date)}",
        "",
        "Visitor Arrivals: #{totals['visitorArrivals']}",
        "Visitor Departures: #{totals['visitorDepartures']}",
        "Visitors Remaining: #{totals['visitorsOnIsland']}",
        "",
        "Event Visitor Arrivals: #{totals['eventVisitorArrivals']}",
        "Event Visitor Departures: #{totals['eventVisitorDepartures']}",
        "Event Visitors Remaining: #{totals['eventVisitorsOnIsland']}"
      ].join("\n")
    end

    def whatsapp_template_parameters(summary_date, totals)
      [
        display_date(summary_date),
        totals["visitorArrivals"].to_i.to_s,
        totals["visitorDepartures"].to_i.to_s,
        totals["visitorsOnIsland"].to_i.to_s,
        totals["eventVisitorArrivals"].to_i.to_s,
        totals["eventVisitorDepartures"].to_i.to_s,
        totals["eventVisitorsOnIsland"].to_i.to_s
      ]
    end

    def send_whatsapp_summary(recipient, summary_date, totals)
      access_token = ENV["WHATSAPP_ACCESS_TOKEN"].to_s
      phone_number_id = ENV["WHATSAPP_PHONE_NUMBER_ID"].to_s
      template_name = ENV["WHATSAPP_TEMPLATE_NAME"].to_s
      template_language = ENV.fetch("WHATSAPP_TEMPLATE_LANGUAGE", "en_US")
      recipient_number = recipient.fetch("number")

      raise Error.new("WhatsApp template name is required for scheduled delivery", status: 503) if template_name.empty?

      uri = URI("https://graph.facebook.com/v22.0/#{phone_number_id}/messages")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{access_token}"
      request["Content-Type"] = "application/json"
      request.body =
        JSON.generate(
          {
            messaging_product: "whatsapp",
            recipient_type: "individual",
            to: recipient_number,
            type: "template",
            template: {
              name: template_name,
              language: { code: template_language },
              components: [
                {
                  type: "body",
                  parameters: whatsapp_template_parameters(summary_date, totals).map do |value|
                    {
                      type: "text",
                      text: value
                    }
                  end
                }
              ]
            }
          }
        )

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        http.request(request)
      end
      return if response.code.to_i.between?(200, 299)

      error_body = response.body.to_s.strip
      raise Error.new("WhatsApp summary failed for #{recipient['name']}: #{response.code} #{error_body}", status: 502)
    end

    def whatsapp_status
      json_response(200, {
        enabled: whatsapp_enabled?,
        ready: whatsapp_ready?,
        recipientCount: configured_whatsapp_recipients.length,
        lastSentAt: @state_store.fetch("lastWhatsappSentAt"),
        lastSendStatus: @state_store.fetch("lastWhatsappSendStatus"),
        lastSentHour: @state_store.fetch("lastWhatsappSummaryHour")
      })
    end

    def session_status(env)
      current_user = current_user_from_env(env)
      raise Error.new("Not signed in", status: 401) unless current_user

      json_response(200, { user: public_user(current_user) })
    end

    def login(body)
      payload = parse_json_body(body)
      username = payload["username"].to_s.strip.downcase
      password = payload["password"].to_s
      raise Error.new("Username is required", status: 400) if username.empty?
      raise Error.new("Password is required", status: 400) if password.empty?

      user = @user_store.read_users.find { |item| item["username"].to_s.downcase == username }
      raise Error.new("Invalid username or password", status: 401) unless user

      password_hash = UserStore.password_hash(password, user["passwordSalt"])
      raise Error.new("Invalid username or password", status: 401) unless password_hash == user["passwordHash"]

      token = SecureRandom.hex(32)
      @sessions[token] = public_user(user)
      json_response(
        200,
        { user: public_user(user) },
        { "Set-Cookie" => session_cookie(token) }
      )
    end

    def logout(env)
      token = parse_cookies(env["HTTP_COOKIE"])["visitor_monitor_session"]
      @sessions.delete(token) if token
      json_response(200, { success: true }, { "Set-Cookie" => expired_session_cookie })
    end

    def list_users
      users = @user_store.read_users.map { |user| public_user(user) }
      json_response(200, users)
    end

    def create_user(body, current_user)
      payload = parse_json_body(body)
      username = payload["username"].to_s.strip
      password = payload["password"].to_s
      role = payload["role"].to_s == "admin" ? "admin" : "user"

      raise Error.new("Username is required", status: 400) if username.empty?
      raise Error.new("Password must be at least 8 characters", status: 400) if password.length < 8

      users = @user_store.read_users
      exists = users.any? { |user| user["username"].to_s.casecmp?(username) }
      raise Error.new("That username already exists", status: 409) if exists

      salt = SecureRandom.hex(16)
      record = {
        "username" => username,
        "role" => role,
        "passwordSalt" => salt,
        "passwordHash" => UserStore.password_hash(password, salt),
        "createdAt" => Time.now.utc.iso8601
      }
      users << record
      @user_store.write_users(users)
      log_event(
        event_type: "user_created",
        actor: current_user["username"].to_s,
        target_type: "user",
        target_id: username,
        details: public_user(record)
      )
      json_response(201, public_user(record))
    end

    def update_user(username, body, current_user)
      payload = parse_json_body(body)
      users = @user_store.read_users
      index = users.index { |user| user["username"].to_s.casecmp?(username) }
      raise Error.new("User not found", status: 404) unless index

      existing = users[index]
      before_user = public_user(existing.dup)
      updated_username = payload["username"].to_s.strip
      updated_username = existing["username"] if updated_username.empty?
      role = payload["role"].to_s == "admin" ? "admin" : "user"
      password = payload["password"].to_s

      duplicate = users.any? do |user|
        !user["username"].to_s.casecmp?(existing["username"].to_s) &&
          user["username"].to_s.casecmp?(updated_username)
      end
      raise Error.new("That username already exists", status: 409) if duplicate

      existing["username"] = updated_username
      existing["role"] = role
      password_changed = false
      if !password.empty?
        raise Error.new("Password must be at least 8 characters", status: 400) if password.length < 8

        salt = SecureRandom.hex(16)
        existing["passwordSalt"] = salt
        existing["passwordHash"] = UserStore.password_hash(password, salt)
        password_changed = true
      end
      users[index] = existing
      @user_store.write_users(users)

      log_event(
        event_type: password_changed ? "user_updated_with_password" : "user_updated",
        actor: current_user["username"].to_s,
        target_type: "user",
        target_id: updated_username,
        details: {
          "before" => before_user,
          "after" => public_user(existing)
        }
      )

      json_response(200, public_user(existing))
    end

    def list_audit_log
      events = @audit_store.read_records.sort_by { |entry| entry["createdAt"].to_s }.reverse.first(250)
      json_response(200, events)
    end

    def list_whatsapp_recipients
      recipients = @whatsapp_store.read_records.sort_by { |recipient| recipient["name"].to_s.downcase }
      json_response(200, recipients)
    end

    def send_test_whatsapp(body, current_user)
      raise Error.new("WhatsApp sending is not configured", status: 503) unless whatsapp_ready?

      payload = parse_json_body(body)
      recipient_id = payload["recipientId"].to_s
      recipients = configured_whatsapp_recipients
      recipient = recipients.find { |entry| entry["id"].to_s == recipient_id } || recipients.first
      raise Error.new("WhatsApp recipient not found", status: 404) unless recipient

      summary_date = operational_today
      totals = calculate_totals(sorted_records.select { |record| operational_date(record["date"], record["time"]) == summary_date })
      send_whatsapp_summary(recipient, summary_date, totals)
      @state_store.write("lastWhatsappSentAt", Time.now.utc.iso8601)
      @state_store.write("lastWhatsappSendStatus", "test_success")
      log_event(
        event_type: "whatsapp_test_sent",
        actor: current_user["username"].to_s,
        target_type: "whatsapp_recipient",
        target_id: recipient["id"],
        details: recipient
      )
      json_response(200, { success: true, recipient: recipient })
    rescue Error => error
      @state_store.write("lastWhatsappSendStatus", "error: #{error.message}")
      raise
    end

    def create_whatsapp_recipient(body, current_user)
      payload = parse_json_body(body)
      recipients = @whatsapp_store.read_records
      recipient = normalize_whatsapp_recipient(payload)
      duplicate = recipients.any? do |entry|
        entry["name"].to_s.casecmp?(recipient["name"]) || entry["number"].to_s == recipient["number"]
      end
      raise Error.new("That WhatsApp recipient already exists", status: 409) if duplicate

      recipients << recipient
      @whatsapp_store.write_records(recipients)
      log_event(
        event_type: "whatsapp_recipient_created",
        actor: current_user["username"].to_s,
        target_type: "whatsapp_recipient",
        target_id: recipient["id"],
        details: recipient
      )
      json_response(201, recipient)
    end

    def update_whatsapp_recipient(id, body, current_user)
      payload = parse_json_body(body)
      recipients = @whatsapp_store.read_records
      index = recipients.index { |recipient| recipient["id"] == id }
      raise Error.new("WhatsApp recipient not found", status: 404) unless index

      existing = recipients[index]
      updated = normalize_whatsapp_recipient(payload, existing["id"], existing)
      duplicate = recipients.any? do |entry|
        entry["id"] != id && (
          entry["name"].to_s.casecmp?(updated["name"]) || entry["number"].to_s == updated["number"]
        )
      end
      raise Error.new("That WhatsApp recipient already exists", status: 409) if duplicate

      recipients[index] = updated
      @whatsapp_store.write_records(recipients)
      log_event(
        event_type: "whatsapp_recipient_updated",
        actor: current_user["username"].to_s,
        target_type: "whatsapp_recipient",
        target_id: updated["id"],
        details: {
          "before" => existing,
          "after" => updated
        }
      )
      json_response(200, updated)
    end

    def delete_whatsapp_recipient(id, current_user)
      recipients = @whatsapp_store.read_records
      index = recipients.index { |recipient| recipient["id"] == id }
      raise Error.new("WhatsApp recipient not found", status: 404) unless index

      deleted = recipients.delete_at(index)
      @whatsapp_store.write_records(recipients)
      log_event(
        event_type: "whatsapp_recipient_deleted",
        actor: current_user["username"].to_s,
        target_type: "whatsapp_recipient",
        target_id: deleted["id"],
        details: deleted
      )
      json_response(200, deleted)
    end

    def report_summary(body)
      payload = parse_json_body(body)
      records = sorted_records
      today = payload["today"].to_s.empty? ? operational_today : payload["today"].to_s
      filters = normalize_filters(payload["filters"] || {})

      filtered = apply_filters(records, filters)
      selected_month = filters["month"] == "all" ? today[0, 7] : filters["month"]
      current_date_records = records.select { |record| operational_date(record["date"], record["time"]) == today }
      selected_date_records = filters["date"] == "all" ? [] : records.select { |record| operational_date(record["date"], record["time"]) == filters["date"] }
      month_records = records.select { |record| month_key(operational_date(record["date"], record["time"])) == selected_month }

      json_response(200, {
        currentDate: summary_payload(current_date_records, label: today),
        selectedDate: summary_payload(selected_date_records, label: filters["date"]),
        selectedMonth: summary_payload(month_records, label: selected_month),
        filtered: summary_payload(filtered, label: filters["date"])
      })
    end

    def export_records(body)
      payload = parse_json_body(body)
      records = sorted_records
      today = payload["today"].to_s.empty? ? operational_today : payload["today"].to_s
      scope = payload["scope"].to_s
      filters = normalize_filters(payload["filters"] || {})

      selected_month = filters["month"] == "all" ? today[0, 7] : filters["month"]
      rows =
        case scope
        when "current_date"
          records.select { |record| operational_date(record["date"], record["time"]) == today }
        when "current_month"
          records.select { |record| month_key(operational_date(record["date"], record["time"])) == selected_month }
        else
          apply_filters(records, filters)
        end

      raise Error.new("There are no records to export", status: 400) if rows.empty?

      summaries =
        case scope
        when "current_date"
          [
            summary_block("Current Date Totals", summary_entries(rows, label: today))
          ]
        when "current_month"
          [
            summary_block("Monthly Totals", month_summary_entries(rows, selected_month))
          ]
        else
          current_rows = records.select { |record| operational_date(record["date"], record["time"]) == today }
          month_rows = records.select { |record| month_key(operational_date(record["date"], record["time"])) == selected_month }
          [
            summary_block("Current Date Totals", basic_summary_entries(current_rows, today)),
            summary_block("Selected Month Totals", basic_month_entries(month_rows, selected_month)),
            summary_block("Filtered View Totals", filtered_summary_entries(rows, filters, selected_month))
          ]
        end

      filename =
        case scope
        when "current_date"
          "visitor-monitor-date-#{today}.csv"
        when "current_month"
          "visitor-monitor-month-#{selected_month}.csv"
        else
          "visitor-monitor-visible-#{today}.csv"
        end

      json_response(200, {
        filename: filename,
        csv: build_csv(rows, summaries)
      })
    end

    def import_records(body, current_user)
      payload = parse_json_body(body)
      csv_text = payload["csv"].to_s
      raise Error.new("Record CSV content is required", status: 400) if csv_text.strip.empty?

      rows = CSV.parse(csv_text)
      header_index = rows.index { |row| row[0] == "Date" && row[1] == "Time" && row[2] == "Movement" }
      raise Error.new("Could not find the record header row in the CSV file", status: 400) unless header_index

      data_rows = rows[(header_index + 1)..].to_a.reject { |row| row.compact.map(&:to_s).all?(&:empty?) }
      imported = data_rows.map do |row|
        normalize_record(
          {
            "date" => iso_from_display_date(row[0]),
            "time" => row[1],
            "movement" => row[2],
            "section" => row[3],
            "boat" => row[4],
            "visitors" => row[5],
            "staffs" => row[6],
            "guests" => row[7],
            "eventVisitors" => row[8],
            "contractors" => row[9],
            "yachtGuests" => row[10],
            "fnf" => row[11],
            "serviceJetty" => row[12],
            "remarks" => row[13],
            "user" => row[14].to_s.strip.empty? ? current_user["username"] : row[14]
          }
        )
      end

      records = @store.read_records
      imported.each do |record|
        duplicate = records.find do |existing|
          existing["date"] == record["date"] &&
            existing["time"] == record["time"] &&
            existing["movement"] == record["movement"] &&
            existing["section"] == record["section"] &&
            existing["boat"] == record["boat"] &&
            existing["user"] == record["user"]
        end
        if duplicate
          record["id"] = duplicate["id"]
          records[records.index(duplicate)] = record
        else
          records << record
        end
      end
      @store.write_records(records)
      log_event(
        event_type: "records_imported",
        actor: current_user["username"].to_s,
        target_type: "records",
        target_id: imported.length.to_s,
        details: { "count" => imported.length }
      )
      json_response(200, { imported: imported.length, totalRecords: records.length })
    end

    def import_users(body, current_user)
      payload = parse_json_body(body)
      csv_text = payload["csv"].to_s
      raise Error.new("User CSV content is required", status: 400) if csv_text.strip.empty?

      rows = CSV.parse(csv_text)
      rows = rows.reject { |row| row.compact.map(&:to_s).all?(&:empty?) }
      header = rows.first || []
      start_index =
        if header[0].to_s.casecmp("username").zero? || header[0].to_s.casecmp("usernames").zero?
          1
        else
          0
        end

      imported_users = rows[start_index..].to_a.filter_map do |row|
        username = row[0].to_s.strip
        password = row[1].to_s.strip
        next if username.empty? || password.empty?

        salt = SecureRandom.hex(16)
        {
          "username" => username,
          "role" => "user",
          "passwordSalt" => salt,
          "passwordHash" => UserStore.password_hash(password, salt),
          "createdAt" => Time.now.utc.iso8601
        }
      end

      users = @user_store.read_users
      imported_users.each do |incoming|
        existing = users.find { |user| user["username"].to_s.casecmp?(incoming["username"]) }
        if existing
          incoming["role"] = existing["role"] == "admin" ? "admin" : "user"
          incoming["createdAt"] = existing["createdAt"] || incoming["createdAt"]
          users[users.index(existing)] = incoming
        else
          users << incoming
        end
      end
      @user_store.write_users(users)
      log_event(
        event_type: "users_imported",
        actor: current_user["username"].to_s,
        target_type: "users",
        target_id: imported_users.length.to_s,
        details: { "count" => imported_users.length }
      )
      json_response(200, { imported: imported_users.length, totalUsers: users.length })
    end

    def backup_export(body)
      payload = parse_json_body(body)
      records = sorted_records
      today = payload["today"].to_s.empty? ? operational_today : payload["today"].to_s
      scope = payload["scope"].to_s

      rows, filename, summaries =
        case scope
        when "daily"
          selected_rows = records.select { |record| operational_date(record["date"], record["time"]) == today }
          [
            selected_rows,
            "visitor-monitor-daily-#{today}.csv",
            [summary_block("Daily Totals", summary_entries(selected_rows, label: today))]
          ]
        when "weekly"
          week_key_value = week_key(today)
          selected_rows = records.select { |record| week_key(operational_date(record["date"], record["time"])) == week_key_value }
          [
            selected_rows,
            "visitor-monitor-weekly-#{week_key_value}.csv",
            [summary_block("Weekly Totals", week_summary_entries(selected_rows, week_key_value))]
          ]
        when "monthly"
          selected_month = month_key(today)
          selected_rows = records.select { |record| month_key(operational_date(record["date"], record["time"])) == selected_month }
          [
            selected_rows,
            "visitor-monitor-monthly-#{selected_month}.csv",
            [summary_block("Monthly Totals", month_summary_entries(selected_rows, selected_month))]
          ]
        else
          raise Error.new("Backup scope must be daily, weekly, or monthly", status: 400)
        end

      raise Error.new("There are no records to export for this backup", status: 400) if rows.empty?

      json_response(200, {
        filename: filename,
        csv: build_csv(rows, summaries)
      })
    end

    def public_user(user)
      {
        "username" => user["username"],
        "role" => user["role"] || "user",
        "createdAt" => user["createdAt"]
      }
    end

    def record_summary(record)
      return {} unless record

      {
        "date" => record["date"],
        "time" => record["time"],
        "movement" => record["movement"],
        "section" => record["section"],
        "boat" => record["boat"],
        "visitors" => record["visitors"],
        "staffs" => record["staffs"],
        "guests" => record["guests"],
        "eventVisitors" => record["eventVisitors"],
        "contractors" => record["contractors"],
        "yachtGuests" => record["yachtGuests"],
        "fnf" => record["fnf"],
        "serviceJetty" => record["serviceJetty"],
        "remarks" => record["remarks"],
        "user" => record["user"]
      }
    end

    def log_event(event_type:, actor:, target_type:, target_id:, details:)
      entries = @audit_store.read_records
      entries << {
        "id" => SecureRandom.uuid,
        "eventType" => event_type,
        "actor" => actor,
        "targetType" => target_type,
        "targetId" => target_id,
        "details" => details,
        "createdAt" => Time.now.utc.iso8601
      }
      @audit_store.write_records(entries.last(1000))
    end

    def import_legacy_json(app_dir)
      @store.import_json_file(File.join(app_dir, "records.json"))
      @user_store.import_json_file(File.join(app_dir, "users.json"))
      @audit_store.import_json_file(File.join(app_dir, "audit_log.json"))
    end

    def sorted_records
      @store.read_records.sort_by { |record| [record["date"], record["time"]] }.reverse
    end

    def normalize_filters(filters)
      {
        "month" => normalize_filter_value(filters["month"], "all"),
        "date" => normalize_filter_value(filters["date"], "all"),
        "section" => normalize_filter_value(filters["section"], "all"),
        "movement" => normalize_filter_value(filters["movement"], "all"),
        "query" => filters["query"].to_s.strip.downcase
      }
    end

    def normalize_filter_value(value, fallback)
      stripped = value.to_s.strip
      stripped.empty? ? fallback : stripped
    end

    def operational_today
      now = Time.now
      now -= 86_400 if now.hour < 6
      now.strftime("%Y-%m-%d")
    end

    def operational_date(iso_date, time_value)
      date = Date.iso8601(iso_date.to_s)
      hour = normalize_time(time_value).split(":").first.to_i
      date -= 1 if hour < 6
      date.iso8601
    rescue Date::Error
      iso_date.to_s
    end

    def apply_filters(records, filters)
      records.select do |record|
        duty_date = operational_date(record["date"], record["time"])
        month_ok = filters["month"] == "all" || month_key(duty_date) == filters["month"]
        date_ok = filters["date"] == "all" || duty_date == filters["date"]
        section_ok = filters["section"] == "all" || record["section"] == filters["section"]
        movement_ok = filters["movement"] == "all" || record["movement"] == filters["movement"]
        query = filters["query"]
        text_ok = query.empty? || [
          display_date(duty_date),
          record["time"],
          record["movement"],
          record["section"],
          record["boat"],
          record["remarks"],
          record["user"]
        ].join(" ").downcase.include?(query)

        month_ok && date_ok && section_ok && movement_ok && text_ok
      end
    end

    def month_key(iso_date)
      iso_date.to_s[0, 7]
    end

    def week_key(iso_date)
      date = Date.iso8601(iso_date.to_s)
      "#{date.cwyear}-W#{format('%02d', date.cweek)}"
    rescue Date::Error
      ""
    end

    def display_date(iso_date)
      return "" if iso_date.to_s.empty?

      iso_date.to_s.split("-").reverse.join(".")
    end

    def calculate_totals(pool)
      pool.each_with_object({
        "visitorArrivals" => 0, "visitorDepartures" => 0, "visitorsOnIsland" => 0,
        "staffArrivals" => 0, "staffDepartures" => 0, "staffsOnIsland" => 0,
        "guestArrivals" => 0, "guestDepartures" => 0, "guestsOnIsland" => 0,
        "eventVisitorArrivals" => 0, "eventVisitorDepartures" => 0, "eventVisitorsOnIsland" => 0,
        "contractorArrivals" => 0, "contractorDepartures" => 0,
        "yachtGuestArrivals" => 0, "yachtGuestDepartures" => 0,
        "fnfArrivals" => 0, "fnfDepartures" => 0,
        "serviceJettyVisitors" => 0
      }) do |record, acc|
        arrival = record["movement"] == "arrival"
        direction = arrival ? 1 : -1
        acc["visitorArrivals"] += arrival ? number_value(record["visitors"]) : 0
        acc["visitorDepartures"] += arrival ? 0 : number_value(record["visitors"])
        acc["visitorsOnIsland"] += direction * number_value(record["visitors"])
        acc["staffArrivals"] += arrival ? number_value(record["staffs"]) : 0
        acc["staffDepartures"] += arrival ? 0 : number_value(record["staffs"])
        acc["staffsOnIsland"] += direction * number_value(record["staffs"])
        acc["guestArrivals"] += arrival ? number_value(record["guests"]) : 0
        acc["guestDepartures"] += arrival ? 0 : number_value(record["guests"])
        acc["guestsOnIsland"] += direction * number_value(record["guests"])
        acc["eventVisitorArrivals"] += arrival ? number_value(record["eventVisitors"]) : 0
        acc["eventVisitorDepartures"] += arrival ? 0 : number_value(record["eventVisitors"])
        acc["eventVisitorsOnIsland"] += direction * number_value(record["eventVisitors"])
        acc["contractorArrivals"] += arrival ? number_value(record["contractors"]) : 0
        acc["contractorDepartures"] += arrival ? 0 : number_value(record["contractors"])
        acc["yachtGuestArrivals"] += arrival ? number_value(record["yachtGuests"]) : 0
        acc["yachtGuestDepartures"] += arrival ? 0 : number_value(record["yachtGuests"])
        acc["fnfArrivals"] += arrival ? number_value(record["fnf"]) : 0
        acc["fnfDepartures"] += arrival ? 0 : number_value(record["fnf"])
        acc["serviceJettyVisitors"] += number_value(record["serviceJetty"])
      end
    end

    def summary_payload(rows, label:)
      {
        "label" => label,
        "totals" => calculate_totals(rows)
      }
    end

    def basic_summary_entries(rows, date)
      totals = calculate_totals(rows)
      [
        ["Date", display_date(date)],
        ["Visitor arrivals", totals["visitorArrivals"]],
        ["Visitor departures", totals["visitorDepartures"]],
        ["Visitors remaining", totals["visitorsOnIsland"]]
      ]
    end

    def basic_month_entries(rows, month)
      totals = calculate_totals(rows)
      [
        ["Month", month],
        ["Visitor arrivals", totals["visitorArrivals"]],
        ["Visitor departures", totals["visitorDepartures"]],
        ["Visitors remaining", totals["visitorsOnIsland"]]
      ]
    end

    def filtered_summary_entries(rows, filters, selected_month)
      totals = calculate_totals(rows)
      [
        ["Month filter", filters["month"] == "all" ? selected_month : filters["month"]],
        ["Date filter", filters["date"] == "all" ? "All Dates" : display_date(filters["date"])],
        ["Visitor arrivals", totals["visitorArrivals"]],
        ["Visitor departures", totals["visitorDepartures"]],
        ["Visitors remaining", totals["visitorsOnIsland"]]
      ]
    end

    def summary_entries(rows, label:)
      totals = calculate_totals(rows)
      [
        ["Date", display_date(label)],
        ["Visitor arrivals", totals["visitorArrivals"]],
        ["Visitor departures", totals["visitorDepartures"]],
        ["Visitors remaining", totals["visitorsOnIsland"]],
        ["Event visitors on island", totals["eventVisitorsOnIsland"]],
        ["Contractor arrivals", totals["contractorArrivals"]],
        ["Contractor departures", totals["contractorDepartures"]]
      ]
    end

    def month_summary_entries(rows, month)
      totals = calculate_totals(rows)
      [
        ["Month", month],
        ["Visitor arrivals", totals["visitorArrivals"]],
        ["Visitor departures", totals["visitorDepartures"]],
        ["Visitors remaining", totals["visitorsOnIsland"]],
        ["Event visitor arrivals", totals["eventVisitorArrivals"]],
        ["Event visitor departures", totals["eventVisitorDepartures"]],
        ["Yacht guest arrivals", totals["yachtGuestArrivals"]],
        ["Yacht guest departures", totals["yachtGuestDepartures"]],
        ["F&F arrivals", totals["fnfArrivals"]],
        ["F&F departures", totals["fnfDepartures"]]
      ]
    end

    def week_summary_entries(rows, week)
      totals = calculate_totals(rows)
      [
        ["Week", week],
        ["Visitor arrivals", totals["visitorArrivals"]],
        ["Visitor departures", totals["visitorDepartures"]],
        ["Visitors remaining", totals["visitorsOnIsland"]],
        ["Event visitor arrivals", totals["eventVisitorArrivals"]],
        ["Event visitor departures", totals["eventVisitorDepartures"]],
        ["Contractor arrivals", totals["contractorArrivals"]],
        ["Contractor departures", totals["contractorDepartures"]],
        ["Yacht guest arrivals", totals["yachtGuestArrivals"]],
        ["Yacht guest departures", totals["yachtGuestDepartures"]],
        ["F&F arrivals", totals["fnfArrivals"]],
        ["F&F departures", totals["fnfDepartures"]]
      ]
    end

    def summary_block(title, entries)
      [[title], *entries, []]
    end

    def build_csv(rows, summary_blocks)
      header = [
        "Date", "Time", "Movement", "Section", "Boat", "Visitors", "Staffs", "Guests",
        "Event Visitors", "Contractors", "Yacht Guests", "F&F", "Service Jetty", "Remarks", "Saved By"
      ]
      summary_lines = summary_blocks.flat_map do |block|
        block.map { |row| row.map { |value| csv_cell(value) }.join(",") }
      end
      row_lines = rows.map do |record|
        [
          display_date(operational_date(record["date"], record["time"])),
          record["time"],
          record["movement"],
          record["section"],
          record["boat"],
          record["visitors"],
          record["staffs"],
          record["guests"],
          record["eventVisitors"],
          record["contractors"],
          record["yachtGuests"],
          record["fnf"],
          record["serviceJetty"],
          record["remarks"],
          record["user"]
        ].map { |value| csv_cell(value) }.join(",")
      end

      (summary_lines + [header.map { |value| csv_cell(value) }.join(",")] + row_lines).join("\n")
    end

    def csv_cell(value)
      "\"#{value.to_s.gsub('"', '""')}\""
    end

    def iso_from_display_date(value)
      text = value.to_s.strip
      return text if text.match?(/^\d{4}-\d{2}-\d{2}$/)

      parts = text.split(".")
      return text unless parts.length == 3

      [parts[2], parts[1], parts[0]].join("-")
    end

    def session_cookie(token)
      "visitor_monitor_session=#{token}; Path=/; HttpOnly; SameSite=Lax"
    end

    def expired_session_cookie
      "visitor_monitor_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"
    end

    def normalize_time(value)
      stripped = value.to_s.strip
      raise Error.new("Missing required fields: time", status: 400) if stripped.empty?

      match = stripped.match(/^([01]?\d|2[0-3]):([0-5]\d)$/)
      raise Error.new("Time must use 24-hour HH:MM format", status: 400) unless match

      format("%02d:%02d", match[1].to_i, match[2].to_i)
    end

    def number_value(value)
      Float(value || 0)
    rescue StandardError
      0
    end

    def normalize_record(payload, existing_id = nil)
      required_text = {
        "date" => payload["date"],
        "movement" => payload["movement"],
        "section" => payload["section"],
        "boat" => payload["boat"],
        "user" => payload["user"]
      }

      missing = required_text.select { |_key, value| value.to_s.strip.empty? }.keys
      raise Error.new("Missing required fields: #{missing.join(', ')}", status: 400) if missing.any?

      normalized_time = normalize_time(payload["time"])
      normalized_date = operational_date(payload["date"].to_s, normalized_time)

      {
        "id" => existing_id || payload["id"] || SecureRandom.uuid,
        "date" => normalized_date,
        "time" => normalized_time,
        "movement" => payload["movement"] == "departure" ? "departure" : "arrival",
        "section" => payload["section"].to_s.strip,
        "boat" => payload["boat"].to_s.strip,
        "visitors" => number_value(payload["visitors"]).to_i,
        "staffs" => number_value(payload["staffs"]).to_i,
        "guests" => number_value(payload["guests"]).to_i,
        "eventVisitors" => number_value(payload["eventVisitors"]).to_i,
        "contractors" => number_value(payload["contractors"]).to_i,
        "yachtGuests" => number_value(payload["yachtGuests"]).to_i,
        "fnf" => number_value(payload["fnf"]).to_i,
        "serviceJetty" => number_value(payload["serviceJetty"]).to_i,
        "remarks" => payload["remarks"].to_s.strip,
        "user" => payload["user"].to_s.strip,
        "updatedAt" => Time.now.utc.iso8601
      }
    end

    def serve_static(path)
      clean_path = path.to_s == "/" || path.to_s.empty? ? "/index.html" : path.to_s
      full_path = File.expand_path(File.join(@public_dir, clean_path.sub(%r{\A/}, "")))
      return not_found_response unless full_path.start_with?(File.expand_path(@public_dir))
      return not_found_response unless File.file?(full_path)

      body = File.binread(full_path)
      [200, default_headers.merge({ "Content-Type" => content_type_for(full_path), "Content-Length" => body.bytesize.to_s }), [body]]
    end

    def not_found_response
      [404, default_headers.merge({ "Content-Type" => "text/plain; charset=utf-8" }), ["Not found"]]
    end

    def json_response(status, payload, extra_headers = {})
      body = JSON.generate(payload)
      headers = default_headers.merge({ "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s }).merge(extra_headers)
      [status, headers, body]
    end

    def default_headers
      {
        "Cache-Control" => "no-store",
        "X-Content-Type-Options" => "nosniff",
        "X-Frame-Options" => "SAMEORIGIN",
        "Referrer-Policy" => "same-origin"
      }
    end

    def content_type_for(path)
      case File.extname(path)
      when ".html" then "text/html; charset=utf-8"
      when ".css" then "text/css; charset=utf-8"
      when ".js" then "application/javascript; charset=utf-8"
      when ".json" then "application/json; charset=utf-8"
      when ".svg" then "image/svg+xml"
      when ".png" then "image/png"
      when ".jpg", ".jpeg" then "image/jpeg"
      else "application/octet-stream"
      end
    end

    def normalize_whatsapp_recipient(payload, existing_id = nil, existing = nil)
      name = payload["name"].to_s.strip
      number = payload["number"].to_s.strip
      raise Error.new("Recipient name is required", status: 400) if name.empty?
      raise Error.new("WhatsApp number is required", status: 400) if number.empty?
      raise Error.new("WhatsApp number must start with + and country code", status: 400) unless number.match?(/^\+\d{7,15}$/)

      {
        "id" => existing_id || payload["id"] || SecureRandom.uuid,
        "name" => name,
        "number" => number,
        "createdAt" => existing&.dig("createdAt") || Time.now.utc.iso8601,
        "updatedAt" => Time.now.utc.iso8601
      }
    end
  end
end
