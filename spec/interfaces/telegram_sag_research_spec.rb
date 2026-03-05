# frozen_string_literal: true

require "spec_helper"

# Test the SAGResearch module methods in isolation using a minimal host class.
RSpec.describe Homunculus::Interfaces::Telegram::SAGResearch do
  let(:test_host) do
    Class.new do
      include Homunculus::Interfaces::Telegram::SAGResearch

      attr_accessor :config, :providers

      def initialize(config:, providers:)
        @config = config
        @providers = providers
      end

      # Expose private methods for testing
      public :build_sag_llm, :build_sag_embedder, :build_sag_pipeline_factory
    end
  end

  let(:sag_config) do
    instance_double(
      Homunculus::SAGConfig,
      enabled: true,
      searxng_url: "http://localhost:8888",
      searxng_categories: ["general"],
      top_n_results: 5,
      deep_fetch: false,
      reranking_strategy: "positional",
      max_tokens: 1024,
      searxng_timeout: 15
    )
  end

  let(:local_model_config) do
    instance_double(Homunculus::ModelConfig, base_url: "http://127.0.0.1:11434")
  end

  let(:memory_config) do
    instance_double(Homunculus::MemoryConfig, embedding_model: "nomic-embed-text")
  end

  let(:config) do
    instance_double(Homunculus::Config, sag: sag_config, models: { local: local_model_config }, memory: memory_config)
  end

  let(:ollama_response) do
    Homunculus::Agent::ModelProvider::Response.new(
      content: "Ollama response about Ractors",
      tool_calls: nil,
      usage: Homunculus::Agent::ModelProvider::TokenUsage.new(input_tokens: 50, output_tokens: 20),
      model: "qwen2.5:14b",
      stop_reason: "end_turn",
      raw_response: {}
    )
  end

  let(:anthropic_response) do
    Homunculus::Agent::ModelProvider::Response.new(
      content: "Anthropic fallback response",
      tool_calls: nil,
      usage: Homunculus::Agent::ModelProvider::TokenUsage.new(input_tokens: 100, output_tokens: 40),
      model: "claude-sonnet-4-20250514",
      stop_reason: "end_turn",
      raw_response: {}
    )
  end

  let(:ollama_provider) { instance_double(Homunculus::Agent::ModelProvider) }
  let(:anthropic_provider) { instance_double(Homunculus::Agent::ModelProvider) }

  describe "#build_sag_llm" do
    context "when ollama succeeds" do
      it "returns ollama response without trying anthropic" do
        allow(ollama_provider).to receive(:complete).and_return(ollama_response)

        host = test_host.new(config: config, providers: { ollama: ollama_provider, anthropic: anthropic_provider })
        llm = host.build_sag_llm

        result = llm.call("What are Ruby Ractors?")
        expect(result).to eq("Ollama response about Ractors")
        expect(ollama_provider).to have_received(:complete).once
      end
    end

    context "when ollama fails and anthropic succeeds" do
      it "falls back to anthropic" do
        allow(ollama_provider).to receive(:complete).and_raise(RuntimeError, "connection refused")
        allow(anthropic_provider).to receive(:complete).and_return(anthropic_response)

        host = test_host.new(config: config, providers: { ollama: ollama_provider, anthropic: anthropic_provider })
        llm = host.build_sag_llm

        result = llm.call("What are Ruby Ractors?")
        expect(result).to eq("Anthropic fallback response")
        expect(ollama_provider).to have_received(:complete).once
        expect(anthropic_provider).to have_received(:complete).once
      end
    end

    context "when all providers fail" do
      it "raises the last error" do
        allow(ollama_provider).to receive(:complete).and_raise(RuntimeError, "ollama down")
        allow(anthropic_provider).to receive(:complete).and_raise(RuntimeError, "anthropic down")

        host = test_host.new(config: config, providers: { ollama: ollama_provider, anthropic: anthropic_provider })
        llm = host.build_sag_llm

        expect { llm.call("What are Ruby Ractors?") }.to raise_error(RuntimeError, "anthropic down")
      end
    end

    context "when only ollama is available and fails" do
      it "raises the error" do
        allow(ollama_provider).to receive(:complete).and_raise(RuntimeError, "model not found")

        host = test_host.new(config: config, providers: { ollama: ollama_provider })
        llm = host.build_sag_llm

        expect { llm.call("test prompt") }.to raise_error(RuntimeError, "model not found")
      end
    end
  end

  describe "#build_sag_embedder" do
    it "returns an Embedder when local config has base_url" do
      host = test_host.new(config: config, providers: {})
      embedder = host.build_sag_embedder

      expect(embedder).to be_a(Homunculus::Memory::Embedder)
    end

    it "returns nil when local config is missing" do
      nil_config = instance_double(Homunculus::Config, sag: sag_config, models: { local: nil }, memory: memory_config)
      host = test_host.new(config: nil_config, providers: {})
      expect(host.build_sag_embedder).to be_nil
    end
  end

  describe "#build_sag_pipeline_factory" do
    it "returns a callable that builds a Pipeline" do
      allow(ollama_provider).to receive(:complete).and_return(ollama_response)

      host = test_host.new(config: config, providers: { ollama: ollama_provider })
      factory = host.build_sag_pipeline_factory

      expect(factory).to respond_to(:call)
      pipeline = factory.call
      expect(pipeline).to be_a(Homunculus::SAG::Pipeline)
    end
  end
end
