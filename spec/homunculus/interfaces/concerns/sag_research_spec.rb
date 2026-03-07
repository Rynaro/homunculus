# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Interfaces::Concerns::SAGResearch do
  let(:test_host_class) do
    Class.new do
      include Homunculus::Interfaces::Concerns::SAGResearch

      attr_accessor :config, :models_router, :providers, :provider

      def initialize(config:, models_router: nil, providers: nil, provider: nil)
        @config = config
        @models_router = models_router
        @providers = providers
        @provider = provider
      end

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

  describe "#build_sag_llm" do
    context "with models_router" do
      it "routes through the models router with workhorse tier and no tools" do
        router = instance_double(Homunculus::Agent::Models::Router)
        router_response = instance_double(Homunculus::Agent::Models::Response, content: "Router response")

        allow(router).to receive(:generate).with(
          hash_including(tier: :workhorse, tools: nil, stream: false)
        ).and_return(router_response)

        host = test_host_class.new(config: config, models_router: router)
        llm = host.build_sag_llm

        result = llm.call("What are Ruby Ractors?")
        expect(result).to eq("Router response")
        expect(router).to have_received(:generate).once
      end
    end

    context "with providers hash" do
      it "uses ollama provider when available" do
        ollama_response = Homunculus::Agent::ModelProvider::Response.new(
          content: "Ollama response",
          tool_calls: nil,
          usage: Homunculus::Agent::ModelProvider::TokenUsage.new(input_tokens: 50, output_tokens: 20),
          model: "qwen2.5:14b",
          stop_reason: "end_turn",
          raw_response: {}
        )

        ollama = instance_double(Homunculus::Agent::ModelProvider)
        allow(ollama).to receive(:complete).and_return(ollama_response)

        host = test_host_class.new(config: config, providers: { ollama: ollama })
        llm = host.build_sag_llm

        result = llm.call("test prompt")
        expect(result).to eq("Ollama response")
      end

      it "falls back to anthropic when ollama fails" do
        anthropic_response = Homunculus::Agent::ModelProvider::Response.new(
          content: "Anthropic fallback",
          tool_calls: nil,
          usage: Homunculus::Agent::ModelProvider::TokenUsage.new(input_tokens: 100, output_tokens: 40),
          model: "claude-sonnet-4-20250514",
          stop_reason: "end_turn",
          raw_response: {}
        )

        ollama = instance_double(Homunculus::Agent::ModelProvider)
        anthropic = instance_double(Homunculus::Agent::ModelProvider)
        allow(ollama).to receive(:complete).and_raise(RuntimeError, "connection refused")
        allow(anthropic).to receive(:complete).and_return(anthropic_response)

        host = test_host_class.new(config: config, providers: { ollama: ollama, anthropic: anthropic })
        llm = host.build_sag_llm

        result = llm.call("test prompt")
        expect(result).to eq("Anthropic fallback")
      end
    end

    context "with single provider" do
      it "uses the single provider directly" do
        provider_response = Homunculus::Agent::ModelProvider::Response.new(
          content: "Single provider response",
          tool_calls: nil,
          usage: Homunculus::Agent::ModelProvider::TokenUsage.new(input_tokens: 50, output_tokens: 20),
          model: "qwen2.5:14b",
          stop_reason: "end_turn",
          raw_response: {}
        )

        provider = instance_double(Homunculus::Agent::ModelProvider)
        allow(provider).to receive(:complete).and_return(provider_response)

        host = test_host_class.new(config: config, provider: provider)
        llm = host.build_sag_llm

        result = llm.call("test prompt")
        expect(result).to eq("Single provider response")
      end
    end
  end

  describe "#build_sag_embedder" do
    it "returns an Embedder when local config has base_url" do
      host = test_host_class.new(config: config)
      embedder = host.build_sag_embedder

      expect(embedder).to be_a(Homunculus::Memory::Embedder)
    end

    it "returns nil when local config is missing" do
      nil_config = instance_double(
        Homunculus::Config,
        sag: sag_config, models: { local: nil }, memory: memory_config
      )
      host = test_host_class.new(config: nil_config)
      expect(host.build_sag_embedder).to be_nil
    end
  end

  describe "#build_sag_pipeline_factory" do
    it "returns a callable that builds a Pipeline" do
      ollama_response = Homunculus::Agent::ModelProvider::Response.new(
        content: "test",
        tool_calls: nil,
        usage: Homunculus::Agent::ModelProvider::TokenUsage.new(input_tokens: 10, output_tokens: 5),
        model: "qwen2.5:14b",
        stop_reason: "end_turn",
        raw_response: {}
      )
      provider = instance_double(Homunculus::Agent::ModelProvider)
      allow(provider).to receive(:complete).and_return(ollama_response)

      host = test_host_class.new(config: config, providers: { ollama: provider })
      factory = host.build_sag_pipeline_factory

      expect(factory).to respond_to(:call)
      pipeline = factory.call
      expect(pipeline).to be_a(Homunculus::SAG::Pipeline)
    end
  end
end
