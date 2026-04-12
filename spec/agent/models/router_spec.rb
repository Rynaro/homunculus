# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Agent::Models::Router do
  let(:ollama_provider) do
    instance_double(Homunculus::Agent::Models::OllamaProvider, name: :ollama)
  end

  let(:llamacpp_provider) do
    instance_double(Homunculus::Agent::Models::LlamaCppProvider, name: :llamacpp)
  end

  let(:anthropic_provider) do
    instance_double(Homunculus::Agent::Models::AnthropicProvider, name: :anthropic)
  end

  let(:base_config) do
    {
      "defaults" => { "escalation_enabled" => true },
      "tiers" => {
        "workhorse" => {
          "provider" => "ollama",
          "model" => "qwen3:14b",
          "temperature" => 0.7,
          "max_tokens" => 4096
        },
        "llamacpp_general" => {
          "provider" => "llamacpp",
          "model" => "llama-3.1-8b",
          "temperature" => 0.7,
          "max_tokens" => 4096
        },
        "cloud_fast" => {
          "provider" => "anthropic",
          "model" => "claude-haiku-4-5-20251001",
          "temperature" => 0.7,
          "max_tokens" => 4096
        },
        "cloud_standard" => {
          "provider" => "anthropic",
          "model" => "claude-sonnet-4-5-20250929",
          "temperature" => 0.7,
          "max_tokens" => 8192
        }
      },
      "routing" => {},
      "escalation" => {
        "max_local_retries" => 1,
        "gibberish_detection" => false
      }
    }
  end

  let(:ollama_response_hash) do
    {
      content: "Hello from Ollama",
      tool_calls: [],
      model: "qwen3:14b",
      usage: { prompt_tokens: 10, completion_tokens: 20, total_tokens: 30 },
      finish_reason: :stop,
      cost_usd: 0.0,
      metadata: {}
    }
  end

  let(:llamacpp_response_hash) do
    {
      content: "Hello from LlamaCpp",
      tool_calls: [],
      model: "llama-3.1-8b",
      usage: { prompt_tokens: 8, completion_tokens: 15, total_tokens: 23 },
      finish_reason: :stop,
      cost_usd: 0.0,
      metadata: {}
    }
  end

  let(:anthropic_response_hash) do
    {
      content: "Hello from Anthropic",
      tool_calls: [],
      model: "claude-haiku-4-5-20251001",
      usage: { prompt_tokens: 12, completion_tokens: 25, total_tokens: 37 },
      finish_reason: :stop,
      cost_usd: 0.001,
      metadata: {}
    }
  end

  let(:messages) { [{ role: "user", content: "Hello" }] }

  describe "LlamaCpp tier routing" do
    context "when llamacpp provider is registered" do
      let(:router) do
        described_class.new(
          config: base_config,
          providers: {
            ollama: ollama_provider,
            llamacpp: llamacpp_provider
          }
        )
      end

      it "routes a llamacpp tier to the LlamaCppProvider" do
        allow(llamacpp_provider).to receive(:generate).and_return(llamacpp_response_hash)

        response = router.generate(messages:, tier: :llamacpp_general)

        expect(llamacpp_provider).to have_received(:generate)
        expect(response.provider).to eq(:llamacpp)
        expect(response.content).to eq("Hello from LlamaCpp")
      end

      it "returns a local? response for llamacpp tier" do
        allow(llamacpp_provider).to receive(:generate).and_return(llamacpp_response_hash)

        response = router.generate(messages:, tier: :llamacpp_general)

        expect(response.local?).to be(true)
      end

      it "does not call the ollama provider when tier is llamacpp" do
        allow(llamacpp_provider).to receive(:generate).and_return(llamacpp_response_hash)
        allow(ollama_provider).to receive(:generate).and_return(ollama_response_hash)

        router.generate(messages:, tier: :llamacpp_general)

        expect(ollama_provider).not_to have_received(:generate)
      end
    end

    context "when llamacpp provider is not registered" do
      let(:router) do
        described_class.new(
          config: base_config,
          providers: { ollama: ollama_provider }
        )
      end

      it "raises ConfigError when a llamacpp tier is requested but provider is absent" do
        expect do
          router.generate(messages:, tier: :llamacpp_general)
        end.to raise_error(Homunculus::Agent::Models::ConfigError, /Provider not registered: llamacpp/)
      end
    end
  end

  describe "escalation from llamacpp tier to cloud" do
    let(:router) do
      described_class.new(
        config: base_config,
        providers: {
          ollama: ollama_provider,
          llamacpp: llamacpp_provider,
          anthropic: anthropic_provider
        }
      )
    end

    it "escalates to cloud when llamacpp provider raises ProviderError beyond max_retries" do
      allow(llamacpp_provider).to receive(:generate)
        .and_raise(Homunculus::Agent::Models::ProviderError, "llama-server unavailable")
      allow(anthropic_provider).to receive(:generate).and_return(anthropic_response_hash)

      response = router.generate(messages:, tier: :llamacpp_general)

      expect(anthropic_provider).to have_received(:generate)
      expect(response.escalated_from).to eq(:llamacpp_general)
    end

    it "sets escalated_from on the response when escalating from llamacpp" do
      allow(llamacpp_provider).to receive(:generate)
        .and_raise(Homunculus::Agent::Models::ProviderError, "connection refused")
      allow(anthropic_provider).to receive(:generate).and_return(anthropic_response_hash)

      response = router.generate(messages:, tier: :llamacpp_general)

      expect(response.escalated_from).to eq(:llamacpp_general)
    end
  end

  describe "ollama tier routing is unaffected when llamacpp is registered" do
    let(:router) do
      described_class.new(
        config: base_config,
        providers: {
          ollama: ollama_provider,
          llamacpp: llamacpp_provider
        }
      )
    end

    it "still routes ollama tier to OllamaProvider" do
      allow(ollama_provider).to receive(:generate).and_return(ollama_response_hash)

      response = router.generate(messages:, tier: :workhorse)

      expect(ollama_provider).to have_received(:generate)
      expect(response.provider).to eq(:ollama)
    end

    it "does not call llamacpp provider when routing an ollama tier" do
      allow(ollama_provider).to receive(:generate).and_return(ollama_response_hash)
      allow(llamacpp_provider).to receive(:generate).and_return(llamacpp_response_hash)

      router.generate(messages:, tier: :workhorse)

      expect(llamacpp_provider).not_to have_received(:generate)
    end
  end
end
