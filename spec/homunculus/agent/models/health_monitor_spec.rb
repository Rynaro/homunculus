# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Agent::Models::HealthMonitor do
  let(:mock_ollama) { instance_double(Homunculus::Agent::Models::OllamaProvider, name: :ollama) }
  let(:mock_anthropic) { instance_double(Homunculus::Agent::Models::AnthropicProvider, name: :anthropic) }
  let(:providers) { { ollama: mock_ollama, anthropic: mock_anthropic } }
  let(:config) { { "health_check_interval_seconds" => 60 } }

  let(:monitor) do
    described_class.new(providers: providers, config: config)
  end

  describe "#ollama_healthy?" do
    it "returns true when Ollama is available" do
      allow(mock_ollama).to receive(:available?).and_return(true)

      expect(monitor.ollama_healthy?).to be true
    end

    it "returns false when Ollama is unreachable" do
      allow(mock_ollama).to receive(:available?).and_return(false)

      expect(monitor.ollama_healthy?).to be false
    end

    it "returns false when Ollama raises an error" do
      allow(mock_ollama).to receive(:available?).and_raise(StandardError, "connection failed")

      expect(monitor.ollama_healthy?).to be false
    end

    it "returns false when no Ollama provider is configured" do
      monitor_no_ollama = described_class.new(providers: { anthropic: mock_anthropic })

      expect(monitor_no_ollama.ollama_healthy?).to be false
    end
  end

  describe "#anthropic_healthy?" do
    it "returns true when API key is available" do
      allow(mock_anthropic).to receive(:available?).and_return(true)

      expect(monitor.anthropic_healthy?).to be true
    end

    it "returns false when API key is missing" do
      allow(mock_anthropic).to receive(:available?).and_return(false)

      expect(monitor.anthropic_healthy?).to be false
    end
  end

  describe "#ollama_loaded_models" do
    it "returns the list of models from Ollama" do
      allow(mock_ollama).to receive(:list_models)
        .and_return(%w[homunculus-workhorse homunculus-coder])

      models = monitor.ollama_loaded_models
      expect(models).to eq(%w[homunculus-workhorse homunculus-coder])
    end

    it "returns empty array when Ollama is down" do
      allow(mock_ollama).to receive(:list_models).and_raise(StandardError, "connection failed")

      expect(monitor.ollama_loaded_models).to eq([])
    end
  end

  describe "#check_all" do
    before do
      allow(mock_ollama).to receive_messages(available?: true, list_models: ["workhorse"])
      allow(mock_anthropic).to receive(:available?).and_return(true)
    end

    it "returns a comprehensive status report" do
      report = monitor.check_all

      expect(report[:ollama][:available]).to be true
      expect(report[:ollama][:loaded_models]).to eq(["workhorse"])
      expect(report[:anthropic][:available]).to be true
      expect(report[:checked_at]).to be_a(String)
    end

    it "updates last_check_at" do
      expect(monitor.last_check_at).to be_nil

      monitor.check_all

      expect(monitor.last_check_at).to be_a(Time)
    end
  end

  describe "#check_due?" do
    it "returns true when no check has been performed" do
      expect(monitor.check_due?).to be true
    end

    it "returns false immediately after a check" do
      allow(mock_ollama).to receive_messages(available?: true, list_models: [])
      allow(mock_anthropic).to receive(:available?).and_return(true)

      monitor.check_all

      expect(monitor.check_due?).to be false
    end
  end

  describe "#status_report" do
    it "runs check_all on first call" do
      allow(mock_ollama).to receive_messages(available?: true, list_models: [])
      allow(mock_anthropic).to receive(:available?).and_return(true)

      report = monitor.status_report

      expect(report).to have_key(:ollama)
      expect(report).to have_key(:anthropic)
    end
  end

  describe "#gpu_status" do
    it "returns unavailable when nvidia-smi is not found" do
      # nvidia-smi is not available in the test environment
      status = monitor.gpu_status
      expect(status[:available]).to be false
    end
  end
end
