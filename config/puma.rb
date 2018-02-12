workers 1
threads 1, 6

app_dir = File.expand_path("../..", __FILE__)
rails_env= ENV.fetch("RAILS_ENV") { "production" }

environment rails_env
bind "tcp://0.0.0.0:80"

app_dir = File.expand_path("../..", __FILE__)
stdout_redirect "#{app_dir}/log/puma.stdout.log", "#{app_dir}/log/puma.stderr.log", true

pidfile "#{app_dir}/tmp/pids/puma.pid"
state_path "#{app_dir}/tmp/pids/puma.state"
activate_control_app

on_worker_boot do
  require "active_record"
  ActiveRecord::Base.connection.disconnect! rescue ActiveRecord::ConnectionNotEstablished
  ActiveRecord::Base.establish_connection(YAML.load_file("#{app_dir}/config/database.yml")[rails_env])
end

plugin :tmp_restart
