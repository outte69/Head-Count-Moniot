max_threads_count = ENV.fetch("RAILS_MAX_THREADS", 5).to_i
threads max_threads_count, max_threads_count

port ENV.fetch("PORT", 4567)
environment ENV.fetch("APP_ENV", "production")

app_dir = File.expand_path("..", __dir__)
rackup File.join(app_dir, "config.ru")

plugin :tmp_restart
