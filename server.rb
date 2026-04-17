#!/usr/bin/env ruby
# frozen_string_literal: true

require "stringio"
require "webrick"
require_relative "app"

APP_DIR = __dir__
PUBLIC_DIR = File.join(APP_DIR, "public")
DATA_FILE = ENV["DATA_FILE"] || File.join(APP_DIR, "records.json")
PORT = (ENV["PORT"] || "4567").to_i

app = VisitorIslandMonitor::App.new(public_dir: PUBLIC_DIR, data_file: DATA_FILE)

server = WEBrick::HTTPServer.new(
  Port: PORT,
  BindAddress: "0.0.0.0",
  DocumentRoot: PUBLIC_DIR,
  AccessLog: [],
  Logger: WEBrick::Log.new($stdout, WEBrick::Log::INFO)
)

server.mount_proc "/" do |request, response|
  rack_env = {
    "REQUEST_METHOD" => request.request_method,
    "PATH_INFO" => request.path,
    "HTTP_COOKIE" => request["cookie"].to_s,
    "rack.input" => StringIO.new(request.body.to_s)
  }

  status, headers, body_parts = app.call(rack_env)
  response.status = status
  headers.each { |key, value| response[key] = value }
  response.body = body_parts.join
end

trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }

puts "Visitor Island Monitor server running on http://0.0.0.0:#{PORT}"
server.start
