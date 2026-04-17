require_relative "app"

app_dir = File.expand_path(__dir__)
public_dir = File.join(app_dir, "public")
data_file = ENV["DATA_FILE"] || File.join(app_dir, "records.json")

run VisitorIslandMonitor::App.new(public_dir: public_dir, data_file: data_file)
