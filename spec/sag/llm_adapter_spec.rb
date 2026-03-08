# frozen_string_literal: true

require_relative "../../lib/homunculus/sag/llm_adapter"
require_relative "../../lib/homunculus/agent/models"

RSpec.describe Homunculus::SAG::LLMAdapter do
  describe "with Models::Router" do
    let(:router) { instance_double(Homunculus::Agent::Models::Router) }
    let(:adapter) { described_class.new(router: router) }

    let(:response) do
      instance_double(Homunculus::Agent::Models::Response, content: "Generated answer about Ruby")
    end

    it "sends prompt as user message with fixed workhorse tier" do
      allow(router).to receive(:generate).and_return(response)

      result = adapter.call("What is Ruby?", max_tokens: 512)

      expect(result).to eq("Generated answer about Ruby")
      expect(router).to have_received(:generate).with(
        messages: [
          { role: "system", content: "You are a research assistant. Answer concisely and accurately." },
          { role: "user", content: "What is Ruby?" }
        ],
        tools: nil,
        tier: :workhorse,
        user_message: "",
        stream: false
      )
    end

    it "returns empty string when content is nil" do
      nil_response = instance_double(Homunculus::Agent::Models::Response, content: nil)
      allow(router).to receive(:generate).and_return(nil_response)

      expect(adapter.call("test")).to eq("")
    end

    it "wraps ProviderError with descriptive message" do
      allow(router).to receive(:generate).and_raise(
        Homunculus::Agent::Models::ProviderError, "Ollama returned 400"
      )

      expect { adapter.call("test") }.to raise_error(StandardError, /Research generation unavailable/)
    end
  end

  describe "with legacy ModelProvider" do
    let(:provider) { instance_double(Homunculus::Agent::ModelProvider) }
    let(:adapter) { described_class.new(provider: provider) }

    let(:response) do
      instance_double(Homunculus::Agent::ModelProvider::Response, content: "Legacy response")
    end

    it "sends prompt via provider.complete" do
      allow(provider).to receive(:complete).and_return(response)

      result = adapter.call("What is Ruby?", max_tokens: 256)

      expect(result).to eq("Legacy response")
      expect(provider).to have_received(:complete).with(
        messages: [
          { role: "system", content: "You are a research assistant. Answer concisely and accurately." },
          { role: "user", content: "What is Ruby?" }
        ],
        tools: nil,
        system: "You are a research assistant. Answer concisely and accurately.",
        max_tokens: 256,
        temperature: 0.3
      )
    end
  end

  describe "initialization" do
    it "raises when neither router nor provider given" do
      expect { described_class.new }.to raise_error(ArgumentError, /Either router: or provider:/)
    end
  end
end
