# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Config do
  describe ".load" do
    subject(:config) { described_class.load("config/default.toml") }

    it "loads TOML configuration" do
      expect(config.gateway.host).to eq("127.0.0.1")
    end

    it "sets the correct gateway port" do
      expect(config.gateway.port).to eq(18_789)
    end

    it "passes gateway validation for 127.0.0.1" do
      expect { config.gateway.validate! }.not_to raise_error
    end

    it "rejects 0.0.0.0 binding" do
      bad_gateway = Homunculus::GatewayConfig.new(host: "0.0.0.0", port: 18_789)
      expect { bad_gateway.validate! }.to raise_error(SecurityError, /MUST bind to 127.0.0.1/)
    end

    it "loads local model configuration" do
      local = config.models[:local]
      expect(local.provider).to eq("ollama")
      expect(local.default_model).to eq("qwen2.5:14b")
      expect(local.context_window).to eq(32_768)
    end

    it "loads escalation model configuration" do
      escalation = config.models[:escalation]
      expect(escalation.provider).to eq("anthropic")
      expect(escalation.model).to eq("claude-sonnet-4-20250514")
      expect(escalation.daily_budget_usd).to eq(2.0)
    end

    it "overrides from environment variables" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("ANTHROPIC_API_KEY", nil).and_return("test-key-123")

      config = described_class.load("config/default.toml")
      expect(config.models[:escalation].api_key).to eq("test-key-123")
    end

    it "overrides local model base_url from OLLAMA_BASE_URL" do
      allow(ENV).to receive(:key?).and_call_original
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:key?).with("OLLAMA_BASE_URL").and_return(true)
      allow(ENV).to receive(:fetch).with("OLLAMA_BASE_URL").and_return("http://ollama:11434")

      config = described_class.load("config/default.toml")
      expect(config.models[:local].base_url).to eq("http://ollama:11434")
    end

    it "loads agent configuration" do
      expect(config.agent.max_turns).to eq(25)
      expect(config.agent.max_execution_time_seconds).to eq(300)
    end

    it "loads tools configuration with sandbox" do
      expect(config.tools.approval_mode).to eq("elevated")
      expect(config.tools.sandbox.enabled).to be(true)
      expect(config.tools.sandbox.network).to eq("none")
    end

    it "loads memory configuration" do
      expect(config.memory.backend).to eq("sqlite")
      expect(config.memory.embedding_model).to eq("nomic-embed-text")
    end

    it "loads security configuration" do
      expect(config.security.audit_log_path).to eq("./data/audit.jsonl")
      expect(config.security.require_confirmation).to include("shell_exec")
    end

    it "loads escalation enabled by default" do
      expect(config.models[:escalation].enabled).to be(true)
      expect(config.escalation_enabled?).to be(true)
    end

    context "with ESCALATION_ENABLED=false" do
      around do |example|
        original = ENV.fetch("ESCALATION_ENABLED", nil)
        ENV["ESCALATION_ENABLED"] = "false"
        example.run
      ensure
        if original
          ENV["ESCALATION_ENABLED"] = original
        else
          ENV.delete("ESCALATION_ENABLED")
        end
      end

      it "disables escalation from environment variable" do
        config = described_class.load("config/default.toml")
        expect(config.models[:escalation].enabled).to be(false)
        expect(config.escalation_enabled?).to be(false)
      end
    end

    context "with ESCALATION_ENABLED=true" do
      around do |example|
        original = ENV.fetch("ESCALATION_ENABLED", nil)
        ENV["ESCALATION_ENABLED"] = "true"
        example.run
      ensure
        if original
          ENV["ESCALATION_ENABLED"] = original
        else
          ENV.delete("ESCALATION_ENABLED")
        end
      end

      it "keeps escalation enabled" do
        config = described_class.load("config/default.toml")
        expect(config.models[:escalation].enabled).to be(true)
        expect(config.escalation_enabled?).to be(true)
      end
    end
  end
end
