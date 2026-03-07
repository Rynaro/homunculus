# frozen_string_literal: true

require "spec_helper"
require "toml-rb"

RSpec.describe "Tool routing integration", type: :integration do
  let(:models_config) { TomlRB.load_file("config/models.toml.example") }
  let(:mock_ollama) { instance_double(Homunculus::Agent::Models::OllamaProvider, name: :ollama) }
  let(:mock_anthropic) { instance_double(Homunculus::Agent::Models::AnthropicProvider, name: :anthropic) }
  let(:providers) { { ollama: mock_ollama, anthropic: mock_anthropic } }
  let(:tracker) { instance_double(Homunculus::Agent::Models::UsageTracker, monthly_cloud_spend_usd: 0.0) }

  let(:router) do
    Homunculus::Agent::Models::Router.new(config: models_config, providers: providers, usage_tracker: tracker)
  end

  let(:tools) do
    [
      { name: "web_research", description: "Research the web",
        parameters: { type: "object", properties: { query: { type: "string" } } } },
      { name: "echo", description: "Echo text",
        parameters: { type: "object", properties: { text: { type: "string" } } } }
    ]
  end

  let(:messages) { [{ role: "user", content: "Hello" }] }

  before do
    allow(tracker).to receive(:record)
  end

  def stub_provider_response(provider, content:, model:, tools_received: nil)
    allow(provider).to receive(:generate) do |**kwargs|
      expect(kwargs[:tools]).to eq(tools_received) if tools_received
      {
        content: content,
        tool_calls: [],
        model: model,
        usage: { prompt_tokens: 100, completion_tokens: 50, total_tokens: 150 },
        finish_reason: :stop,
        cost_usd: 0.0,
        metadata: {}
      }
    end
  end

  context "keyword 'research' routes to thinker tier with tools stripped" do
    it "selects thinker tier and strips tools from the payload" do
      stub_provider_response(mock_ollama, content: "Analysis complete.", model: "homunculus-thinker", tools_received: nil)

      response = router.generate(
        messages: messages,
        tools: tools,
        user_message: "Make a research about models fine-tunning"
      )

      expect(response.tier).to eq(:thinker)
      expect(response.content).to eq("Analysis complete.")
      expect(mock_ollama).to have_received(:generate).with(hash_including(tools: nil))
    end
  end

  context "keyword 'code' routes to coder tier with tools passed" do
    it "selects coder tier and passes tools through" do
      stub_provider_response(mock_ollama, content: "Here's the code fix.", model: "homunculus-coder", tools_received: tools)

      response = router.generate(
        messages: messages,
        tools: tools,
        user_message: "Help me code a new feature"
      )

      expect(response.tier).to eq(:coder)
      expect(response.content).to eq("Here's the code fix.")
      expect(mock_ollama).to have_received(:generate).with(hash_including(tools: tools))
    end
  end

  context "no keyword defaults to workhorse with tools passed" do
    it "selects workhorse tier and passes tools through" do
      stub_provider_response(mock_ollama, content: "Hello! How can I help?", model: "homunculus-workhorse", tools_received: tools)

      response = router.generate(
        messages: messages,
        tools: tools,
        user_message: "Hello, how are you?"
      )

      expect(response.tier).to eq(:workhorse)
      expect(response.content).to eq("Hello! How can I help?")
      expect(mock_ollama).to have_received(:generate).with(hash_including(tools: tools))
    end
  end

  context "thinker tier error still escalates to cloud" do
    it "escalates to cloud tier which receives tools" do
      allow(mock_ollama).to receive(:generate)
        .and_raise(Homunculus::Agent::Models::ProviderError, "model error")

      allow(mock_anthropic).to receive(:generate) do |**kwargs|
        expect(kwargs[:tools]).to eq(tools)
        {
          content: "Cloud response with tools.",
          tool_calls: [],
          model: "claude-haiku-4-5-20251001",
          usage: { prompt_tokens: 200, completion_tokens: 100, total_tokens: 300 },
          finish_reason: :stop,
          cost_usd: 0.001,
          metadata: {}
        }
      end

      response = router.generate(
        messages: messages,
        tools: tools,
        user_message: "Make a research about AI"
      )

      expect(response.escalated?).to be true
      expect(response.cloud?).to be true
    end
  end

  context "streaming with tool-incompatible tier" do
    it "strips tools during streaming too" do
      allow(mock_ollama).to receive(:generate_stream) do |**kwargs|
        expect(kwargs[:tools]).to be_nil
        {
          content: "Streamed analysis.",
          tool_calls: [],
          model: "homunculus-thinker",
          usage: { prompt_tokens: 100, completion_tokens: 50, total_tokens: 150 },
          finish_reason: :stop,
          cost_usd: 0.0,
          metadata: {}
        }
      end

      response = router.generate(
        messages: messages,
        tools: tools,
        user_message: "research quantum computing",
        stream: true
      ) { |chunk| chunk }

      expect(response.tier).to eq(:thinker)
      expect(mock_ollama).to have_received(:generate_stream).with(hash_including(tools: nil))
    end
  end
end
