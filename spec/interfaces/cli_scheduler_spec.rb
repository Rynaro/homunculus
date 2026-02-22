# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/homunculus/interfaces/cli"

RSpec.describe Homunculus::Interfaces::CLI do
  let(:workspace_dir) { Dir.mktmpdir }
  let(:db_dir) { Dir.mktmpdir }

  let(:config) do
    raw = TomlRB.load_file("config/default.toml")
    raw["agent"] = { "workspace_path" => workspace_dir }
    raw["scheduler"] = {
      "enabled" => true,
      "db_path" => File.join(db_dir, "scheduler.db"),
      "heartbeat" => {
        "enabled" => true,
        "cron" => "*/30 8-22 * * *",
        "model" => "local",
        "active_hours_start" => 8,
        "active_hours_end" => 22,
        "timezone" => "UTC"
      },
      "notification" => {
        "max_per_hour" => 10,
        "quiet_hours_queue" => true
      }
    }
    Homunculus::Config.new(raw)
  end

  before do
    # Write HEARTBEAT.md so heartbeat setup succeeds
    File.write(File.join(workspace_dir, "HEARTBEAT.md"), <<~MD)
      # Heartbeat Checklist
      - [ ] (WK) Remind about dev meeting at 13:00
    MD

    # Stub Sequel to use in-memory databases
    allow(Sequel).to receive(:sqlite) { Sequel.connect("sqlite:/") }
  end

  after do
    FileUtils.rm_rf(workspace_dir)
    FileUtils.rm_rf(db_dir)
  end

  describe "scheduler integration" do
    it "initializes the scheduler when enabled" do
      cli = described_class.new(config:)

      scheduler_manager = cli.instance_variable_get(:@scheduler_manager)
      expect(scheduler_manager).not_to be_nil
    end

    it "does not initialize scheduler when disabled" do
      raw = TomlRB.load_file("config/default.toml")
      raw["agent"] = { "workspace_path" => workspace_dir }
      raw["scheduler"] = {
        "enabled" => false,
        "db_path" => File.join(db_dir, "scheduler.db"),
        "heartbeat" => {
          "enabled" => false,
          "cron" => "*/30 8-22 * * *",
          "model" => "local",
          "active_hours_start" => 8,
          "active_hours_end" => 22,
          "timezone" => "UTC"
        },
        "notification" => {
          "max_per_hour" => 10,
          "quiet_hours_queue" => true
        }
      }
      disabled_config = Homunculus::Config.new(raw)

      cli = described_class.new(config: disabled_config)

      scheduler_manager = cli.instance_variable_get(:@scheduler_manager)
      expect(scheduler_manager).to be_nil
    end
  end

  describe "notification delivery" do
    it "builds a notification service with a CLI deliver_fn" do
      cli = described_class.new(config:)

      scheduler_manager = cli.instance_variable_get(:@scheduler_manager)
      notification = scheduler_manager&.instance_variable_get(:@notification)

      expect(notification).not_to be_nil
      expect(notification.instance_variable_get(:@deliver_fn)).not_to be_nil
    end

    it "prints notification to stdout" do
      cli = described_class.new(config:)

      notification = cli.instance_variable_get(:@scheduler_manager)
                        &.instance_variable_get(:@notification)

      output = +""
      allow($stdout).to receive(:puts) { |msg| output << "#{msg}\n" }
      allow($stdout).to receive(:print)
      allow($stdout).to receive(:flush)

      # Stub active hours so delivery goes through
      allow(notification).to receive(:quiet_hours?).and_return(false)

      result = notification.notify("Test reminder: dev meeting in 15 minutes")

      expect(result).to eq(:delivered)
      expect(output).to include("Test reminder")
      expect(output).to include("Scheduler")
    end
  end

  describe "scheduler command" do
    it "prints scheduler status" do
      cli = described_class.new(config:)
      scheduler_manager = cli.instance_variable_get(:@scheduler_manager)
      scheduler_manager&.start

      output = +""
      allow($stdout).to receive(:puts) { |msg| output << "#{msg}\n" }
      allow($stdout).to receive(:write) { |msg| output << msg.to_s }

      cli.send(:print_scheduler_status)

      expect(output).to include("Scheduler Status")
      expect(output).to include("Running")
      expect(output).to include("Jobs")

      scheduler_manager&.stop
    end

    it "shows message when scheduler is not running" do
      raw = TomlRB.load_file("config/default.toml")
      raw["agent"] = { "workspace_path" => workspace_dir }
      raw["scheduler"] = {
        "enabled" => false,
        "db_path" => File.join(db_dir, "scheduler.db"),
        "heartbeat" => {
          "enabled" => false,
          "cron" => "*/30 8-22 * * *",
          "model" => "local",
          "active_hours_start" => 8,
          "active_hours_end" => 22,
          "timezone" => "UTC"
        },
        "notification" => {
          "max_per_hour" => 10,
          "quiet_hours_queue" => true
        }
      }
      disabled_config = Homunculus::Config.new(raw)

      cli = described_class.new(config: disabled_config)

      output = +""
      allow($stdout).to receive(:puts) { |msg| output << "#{msg}\n" }

      cli.send(:print_scheduler_status)

      expect(output).to include("not running")
    end
  end
end
