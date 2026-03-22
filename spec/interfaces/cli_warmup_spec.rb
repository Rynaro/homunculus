# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/homunculus/interfaces/cli"

RSpec.describe Homunculus::Interfaces::CLI do
  let(:workspace_dir) { Dir.mktmpdir }
  let(:db_dir) { Dir.mktmpdir }

  let(:config) do
    raw = TomlRB.load_file("config/default.toml")
    raw["agent"] = { "workspace_path" => workspace_dir }
    raw["sag"] = { "enabled" => false }
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
        raw["sag"] = { "enabled" => false }
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

  describe "model management commands" do
    let(:cli) { described_class.new(config:) }
    let(:session) { Homunculus::Session.new }

    before do
      cli.instance_variable_set(:@session, session)
      cli.instance_variable_set(:@running, true)
    end

    describe "#handle_model_command" do
      context "when no tier argument given" do
        it "prints current override status when no forced_tier" do
          output = +""
          allow($stdout).to receive(:puts) { |msg| output << "#{msg}\n" }

          cli.send(:handle_model_command, "model")

          expect(output).to include("No model override")
        end

        it "prints the current forced_tier when set" do
          session.forced_tier = :coder
          output = +""
          allow($stdout).to receive(:puts) { |msg| output << "#{msg}\n" }

          cli.send(:handle_model_command, "model")

          expect(output).to include("coder")
        end
      end

      context "when a valid tier name is given" do
        before do
          cli.instance_variable_set(:@models_toml_data, { "tiers" => { "coder" => { "model" => "qwen2.5:14b" } } })
        end

        it "sets session.forced_tier" do
          allow($stdout).to receive(:puts)

          cli.send(:handle_model_command, "model coder")

          expect(session.forced_tier).to eq(:coder)
        end

        it "resets first_message_sent" do
          session.first_message_sent = true
          allow($stdout).to receive(:puts)

          cli.send(:handle_model_command, "model coder")

          expect(session.first_message_sent).to be false
        end

        it "prints confirmation" do
          output = +""
          allow($stdout).to receive(:puts) { |msg| output << "#{msg}\n" }

          cli.send(:handle_model_command, "model coder")

          expect(output).to include("coder")
        end
      end

      context "when an unknown tier name is given" do
        before do
          cli.instance_variable_set(:@models_toml_data, { "tiers" => { "coder" => {} } })
        end

        it "prints error listing valid tiers" do
          output = +""
          allow($stdout).to receive(:puts) { |msg| output << "#{msg}\n" }

          cli.send(:handle_model_command, "model nonexistent")

          expect(output).to include("Unknown tier")
          expect(output).to include("coder")
        end

        it "does not change session.forced_tier" do
          session.forced_tier = :coder
          allow($stdout).to receive(:puts)

          cli.send(:handle_model_command, "model nonexistent")

          expect(session.forced_tier).to eq(:coder)
        end
      end
    end

    describe "#handle_routing_command" do
      it "enables routing with 'routing on'" do
        session.routing_enabled = false
        allow($stdout).to receive(:puts)

        cli.send(:handle_routing_command, "routing on")

        expect(session.routing_enabled).to be true
      end

      it "disables routing with 'routing off'" do
        session.routing_enabled = true
        allow($stdout).to receive(:puts)

        cli.send(:handle_routing_command, "routing off")

        expect(session.routing_enabled).to be false
      end

      it "shows current state when no argument given" do
        output = +""
        allow($stdout).to receive(:puts) { |msg| output << "#{msg}\n" }

        cli.send(:handle_routing_command, "routing ")

        expect(output).to include("Routing:")
      end

      it "prints usage for unknown argument" do
        output = +""
        allow($stdout).to receive(:puts) { |msg| output << "#{msg}\n" }

        cli.send(:handle_routing_command, "routing sideways")

        expect(output).to include("Usage")
      end
    end

    describe "#print_models" do
      it "prints tier list when models_toml_data is available" do
        cli.instance_variable_set(
          :@models_toml_data,
          { "tiers" => { "workhorse" => { "model" => "qwen2.5:14b", "description" => "Default local tier" } } }
        )
        output = +""
        allow($stdout).to receive(:puts) { |msg| output << "#{msg}\n" }

        cli.send(:print_models)

        expect(output).to include("workhorse")
        expect(output).to include("qwen2.5:14b")
      end

      it "shows routing state" do
        cli.instance_variable_set(:@models_toml_data, nil)
        output = +""
        allow($stdout).to receive(:puts) { |msg| output << "#{msg}\n" }

        cli.send(:print_models)

        expect(output).to include("Routing:")
      end
    end

    describe "#available_tier_names" do
      it "returns empty array when models_toml_data is nil" do
        cli.instance_variable_set(:@models_toml_data, nil)

        expect(cli.send(:available_tier_names)).to eq([])
      end

      it "returns tier names from models_toml_data" do
        cli.instance_variable_set(:@models_toml_data, { "tiers" => { "coder" => {}, "workhorse" => {} } })

        expect(cli.send(:available_tier_names)).to contain_exactly("coder", "workhorse")
      end
    end
  end

  describe "context window display" do
    let(:cli) { described_class.new(config:) }

    before do
      allow(Sequel).to receive(:sqlite) { Sequel.connect("sqlite:/") }
    end

    describe "#resolved_context_window" do
      it "returns config local context_window when @current_context_window is nil" do
        cli.instance_variable_set(:@current_context_window, nil)
        expect(cli.send(:resolved_context_window)).to eq(config.models[:local].context_window)
      end

      it "returns @current_context_window when set" do
        cli.instance_variable_set(:@current_context_window, 16_384)
        expect(cli.send(:resolved_context_window)).to eq(16_384)
      end
    end

    describe "#update_context_window_from_result" do
      it "sets @current_context_window from result" do
        session = Homunculus::Session.new
        result = Homunculus::Agent::AgentResult.completed("ok", session:, context_window: 200_000)
        cli.send(:update_context_window_from_result, result)
        expect(cli.instance_variable_get(:@current_context_window)).to eq(200_000)
      end

      it "does not update when result has no context_window" do
        cli.instance_variable_set(:@current_context_window, 32_768)
        session = Homunculus::Session.new
        result = Homunculus::Agent::AgentResult.completed("ok", session:)
        cli.send(:update_context_window_from_result, result)
        expect(cli.instance_variable_get(:@current_context_window)).to eq(32_768)
      end
    end

    describe "#build_usage_summary_string" do
      let(:session) { Homunculus::Session.new }

      before do
        cli.instance_variable_set(:@session, session)
        session.track_usage(
          Homunculus::Agent::ModelProvider::TokenUsage.new(input_tokens: 1000, output_tokens: 500)
        )
      end

      it "returns base string without ctx info when ctx_win is nil" do
        result = cli.send(:build_usage_summary_string, nil)
        expect(result).to eq("  [tokens: 1000↓ 500↑ | turns: 0]")
        expect(result).not_to include("ctx:")
      end

      it "includes ctx usage when ctx_win is provided" do
        result = cli.send(:build_usage_summary_string, 32_768)
        expect(result).to include("ctx: 1500/32768")
        expect(result).to match(/\(\d+%\)/)
      end

      it "calculates percentage correctly" do
        result = cli.send(:build_usage_summary_string, 10_000)
        expect(result).to include("(15%)")
      end
    end
  end
end
