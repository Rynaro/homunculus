# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Agent::Models::HealthMonitor do
  let(:ollama_provider) { instance_double(Homunculus::Agent::Models::OllamaProvider) }
  let(:anthropic_provider) { instance_double(Homunculus::Agent::Models::AnthropicProvider) }
  let(:llamacpp_provider) do
    instance_double(Homunculus::Agent::Models::LlamaCppProvider).tap do |p|
      allow(p).to receive(:instance_variable_get).with(:@base_url).and_return("http://127.0.0.1:8080")
    end
  end

  let(:providers) { { ollama: ollama_provider, anthropic: anthropic_provider, llamacpp: llamacpp_provider } }
  let(:monitor) { described_class.new(providers: providers) }

  before do
    allow(ollama_provider).to receive_messages(available?: true, list_models: ["qwen2.5:14b"])
    allow(anthropic_provider).to receive(:available?).and_return(true)
    allow(llamacpp_provider).to receive(:available?).and_return(true)
    # Suppress nvidia-smi invocation in tests
    allow(monitor).to receive(:parse_nvidia_smi).and_return({ available: false, error: "nvidia-smi not available" })
  end

  # ── llamacpp_healthy? ────────────────────────────────────────────────────────

  describe "#llamacpp_healthy?" do
    context "when llama-server is running" do
      it "returns true" do
        allow(llamacpp_provider).to receive(:available?).and_return(true)

        expect(monitor.llamacpp_healthy?).to be(true)
      end
    end

    context "when llama-server is down" do
      it "returns false" do
        allow(llamacpp_provider).to receive(:available?).and_return(false)

        expect(monitor.llamacpp_healthy?).to be(false)
      end
    end

    context "when the provider raises a connection error" do
      it "returns false" do
        allow(llamacpp_provider).to receive(:available?).and_raise(Errno::ECONNREFUSED, "Connection refused")

        expect(monitor.llamacpp_healthy?).to be(false)
      end
    end

    context "when llamacpp provider is not configured" do
      let(:monitor) { described_class.new(providers: {}) }

      it "returns false" do
        expect(monitor.llamacpp_healthy?).to be(false)
      end
    end
  end

  # ── llamacpp_loaded_models ───────────────────────────────────────────────────

  describe "#llamacpp_loaded_models" do
    let(:models_body) do
      {
        "object" => "list",
        "data" => [
          { "id" => "mistral-7b-instruct", "object" => "model" }
        ]
      }
    end

    context "when the server responds with a model list" do
      it "returns the model IDs" do
        stub_request(:get, "http://127.0.0.1:8080/v1/models")
          .to_return(status: 200, body: JSON.generate(models_body),
                     headers: { "Content-Type" => "application/json" })

        expect(monitor.llamacpp_loaded_models).to eq(["mistral-7b-instruct"])
      end
    end

    context "when the server returns an empty data array" do
      it "returns an empty array" do
        stub_request(:get, "http://127.0.0.1:8080/v1/models")
          .to_return(status: 200, body: JSON.generate({ "data" => [] }),
                     headers: { "Content-Type" => "application/json" })

        expect(monitor.llamacpp_loaded_models).to eq([])
      end
    end

    context "when the server is unreachable" do
      it "returns an empty array" do
        stub_request(:get, "http://127.0.0.1:8080/v1/models")
          .to_return(status: 503, body: "Service Unavailable")

        expect(monitor.llamacpp_loaded_models).to eq([])
      end
    end

    context "when llamacpp provider is not configured" do
      let(:monitor) { described_class.new(providers: {}) }

      it "returns an empty array" do
        expect(monitor.llamacpp_loaded_models).to eq([])
      end
    end
  end

  # ── check_all ───────────────────────────────────────────────────────────────

  describe "#check_all" do
    let(:models_body) do
      {
        "data" => [{ "id" => "mistral-7b-instruct", "object" => "model" }]
      }
    end

    before do
      stub_request(:get, "http://127.0.0.1:8080/v1/models")
        .to_return(status: 200, body: JSON.generate(models_body),
                   headers: { "Content-Type" => "application/json" })
    end

    it "includes a :llamacpp key in the result" do
      result = monitor.check_all

      expect(result).to have_key(:llamacpp)
    end

    it "reports llamacpp as available when server is up" do
      result = monitor.check_all

      expect(result[:llamacpp][:available]).to be(true)
    end

    it "includes loaded models in the llamacpp result" do
      result = monitor.check_all

      expect(result[:llamacpp][:loaded_models]).to eq(["mistral-7b-instruct"])
      expect(result[:llamacpp][:model_count]).to eq(1)
    end

    it "includes ollama, anthropic, gpu, and checked_at keys" do
      result = monitor.check_all

      expect(result.keys).to include(:ollama, :anthropic, :llamacpp, :gpu, :checked_at)
    end
  end

  # ── check_llamacpp (via check_all) — not configured ─────────────────────────

  describe "llamacpp not configured" do
    let(:monitor) { described_class.new(providers: { ollama: ollama_provider, anthropic: anthropic_provider }) }

    before do
      allow(monitor).to receive(:parse_nvidia_smi).and_return({ available: false, error: "nvidia-smi not available" })
    end

    it "reports available: false with reason 'not configured' in check_all" do
      result = monitor.check_all

      expect(result[:llamacpp]).to eq({ available: false, reason: "not configured" })
    end

    it "does not make any HTTP requests to the llamacpp server" do
      stub = stub_request(:get, /127\.0\.0\.1:8080/)
      monitor.check_all
      expect(stub).not_to have_been_requested
    end
  end

  # ── error propagation in check_llamacpp ─────────────────────────────────────

  describe "check_llamacpp error handling" do
    it "returns available: false with error message when provider.available? raises" do
      allow(llamacpp_provider).to receive(:available?).and_raise(StandardError, "timeout")

      # Trigger check_llamacpp via the public check_all
      result = monitor.check_all

      expect(result[:llamacpp][:available]).to be(false)
      expect(result[:llamacpp][:error]).to eq("timeout")
    end
  end
end
