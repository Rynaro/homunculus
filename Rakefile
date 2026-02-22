# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

namespace :homunculus do
  desc "Start the Homunculus agent"
  task :start do
    exec "ruby", "bin/homunculus"
  end

  desc "Open an interactive console"
  task :console do
    exec "ruby", "bin/console"
  end

  desc "Validate configuration"
  task :validate_config do
    require_relative "config/boot"
    config = Homunculus::Config.load
    config.gateway.validate!
    puts "Configuration valid."
  end
end
