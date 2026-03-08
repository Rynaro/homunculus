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
    Homunculus::Config.new(raw)
  end

  before do
    allow(Sequel).to receive(:sqlite) { Sequel.connect("sqlite:/") }
  end

  after do
    FileUtils.rm_rf(workspace_dir)
    FileUtils.rm_rf(db_dir)
  end

  describe "warmup integration" do
    it "creates a Warmup instance during initialization" do
      cli = described_class.new(config:)
      warmup = cli.instance_variable_get(:@warmup)

      expect(warmup).to be_a(Homunculus::Agent::Warmup)
    end

    it "passes nil for ollama_provider in single-provider mode" do
      allow(File).to receive(:file?).and_call_original
      allow(File).to receive(:file?).with(File.expand_path("config/models.toml", Dir.pwd)).and_return(false)

      cli = described_class.new(config:)
      warmup = cli.instance_variable_get(:@warmup)
      ollama = warmup.instance_variable_get(:@ollama_provider)

      expect(ollama).to be_nil
    end

    describe "#start_warmup!" do
      it "calls warmup.start! with a callback" do
        cli = described_class.new(config:)
        warmup = cli.instance_variable_get(:@warmup)

        expect(warmup).to receive(:start!).with(callback: anything)

        cli.send(:start_warmup!)
      end

      it "does nothing when warmup is nil" do
        cli = described_class.new(config:)
        cli.instance_variable_set(:@warmup, nil)

        expect { cli.send(:start_warmup!) }.not_to raise_error
      end

      it "does nothing when warmup is disabled" do
        raw = TomlRB.load_file("config/default.toml")
        raw["agent"] = {
          "workspace_path" => workspace_dir,
          "warmup" => { "enabled" => false }
        }
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
        warmup = cli.instance_variable_get(:@warmup)

        expect(warmup).not_to receive(:start!)

        cli.send(:start_warmup!)
      end
    end

    describe "#warmup_display" do
      let(:cli) { described_class.new(config:) }

      it "prints progress on :start event" do
        output = +""
        allow($stdout).to receive(:puts) { |msg| output << "#{msg}\n" }
        allow($stdout).to receive(:write) { |msg| output << msg.to_s }

        cli.send(:warmup_display, :start, :preload_chat_model, {})

        expect(output).to include("Loading chat model...")
      end

      it "prints elapsed time on :complete event" do
        output = +""
        allow($stdout).to receive(:puts) { |msg| output << "#{msg}\n" }
        allow($stdout).to receive(:write) { |msg| output << msg.to_s }

        cli.send(:warmup_display, :complete, :preload_chat_model, { elapsed_ms: 250 })

        expect(output).to include("Loading chat model")
        expect(output).to include("250ms")
      end

      it "prints nothing on :skip event" do
        expect($stdout).not_to receive(:puts)

        cli.send(:warmup_display, :skip, :preload_chat_model, {})
      end

      it "prints error on :fail event" do
        output = +""
        allow($stdout).to receive(:puts) { |msg| output << "#{msg}\n" }
        allow($stdout).to receive(:write) { |msg| output << msg.to_s }

        cli.send(:warmup_display, :fail, :preload_embedding_model, { error: "connection refused" })

        expect(output).to include("Loading embedding model")
        expect(output).to include("connection refused")
      end

      it "prints ready line and separator on :done event" do
        output = +""
        allow($stdout).to receive(:puts) { |msg| output << "#{msg}\n" }
        allow($stdout).to receive(:write) { |msg| output << msg.to_s }

        cli.send(:warmup_display, :done, nil, { elapsed_ms: 1200 })

        expect(output).to include("Ready")
        expect(output).to include("1200ms")
        expect(output).to include("-" * 60)
      end
    end

    describe "#warmup_step_label" do
      let(:cli) { described_class.new(config:) }

      it "returns correct labels" do
        expect(cli.send(:warmup_step_label, :preload_chat_model)).to eq("Loading chat model")
        expect(cli.send(:warmup_step_label, :preload_embedding_model)).to eq("Loading embedding model")
        expect(cli.send(:warmup_step_label, :preread_workspace_files)).to eq("Pre-reading workspace")
      end
    end
  end
end
