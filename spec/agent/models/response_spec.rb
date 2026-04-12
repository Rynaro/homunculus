# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Agent::Models::Response do
  let(:base_attrs) do
    {
      content: "Hello",
      tool_calls: [],
      model: "qwen3:14b",
      tier: :workhorse,
      usage: { prompt_tokens: 10, completion_tokens: 20, total_tokens: 30 },
      latency_ms: 500,
      cost_usd: 0.0,
      finish_reason: :stop,
      escalated_from: nil,
      metadata: {}
    }
  end

  def build(overrides = {})
    described_class.new(**base_attrs, **overrides)
  end

  describe "#local?" do
    it "returns true for :ollama provider" do
      expect(build(provider: :ollama).local?).to be(true)
    end

    it "returns true for :llamacpp provider" do
      expect(build(provider: :llamacpp).local?).to be(true)
    end

    it "returns false for :anthropic provider" do
      expect(build(provider: :anthropic).local?).to be(false)
    end
  end

  describe "#cloud?" do
    it "returns false for :ollama provider" do
      expect(build(provider: :ollama).cloud?).to be(false)
    end

    it "returns false for :llamacpp provider" do
      expect(build(provider: :llamacpp).cloud?).to be(false)
    end

    it "returns true for :anthropic provider" do
      expect(build(provider: :anthropic).cloud?).to be(true)
    end

    it "is the inverse of local?" do
      %i[ollama llamacpp anthropic].each do |prov|
        response = build(provider: prov)
        expect(response.cloud?).to eq(!response.local?)
      end
    end
  end

  describe "#tool_use?" do
    it "returns false when tool_calls is empty" do
      expect(build(provider: :ollama, tool_calls: []).tool_use?).to be(false)
    end

    it "returns true when tool_calls is non-empty" do
      expect(build(provider: :ollama, tool_calls: [{ name: "echo", arguments: {} }]).tool_use?).to be(true)
    end
  end

  describe "#escalated?" do
    it "returns false when escalated_from is nil" do
      expect(build(provider: :ollama, escalated_from: nil).escalated?).to be(false)
    end

    it "returns true when escalated_from is set" do
      expect(build(provider: :anthropic, escalated_from: :workhorse).escalated?).to be(true)
    end
  end

  describe "#to_audit_hash" do
    it "includes provider, model, tier, usage, latency_ms, cost_usd, finish_reason, escalated_from, and timestamp" do
      response = build(provider: :llamacpp, model: "model.gguf", tier: :workhorse)
      hash = response.to_audit_hash

      expect(hash).to include(
        provider: :llamacpp,
        model: "model.gguf",
        tier: :workhorse,
        finish_reason: :stop,
        escalated_from: nil
      )
      expect(hash[:timestamp]).to be_a(String)
    end
  end

  describe "Homunculus::Agent::Models::LOCAL_PROVIDERS constant" do
    subject(:local_providers) { Homunculus::Agent::Models::LOCAL_PROVIDERS }

    it "includes :ollama and :llamacpp" do
      expect(local_providers).to contain_exactly(:ollama, :llamacpp)
    end

    it "is frozen" do
      expect(local_providers).to be_frozen
    end
  end
end
