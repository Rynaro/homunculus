# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Agent::Models::AnthropicProvider do
  let(:config) do
    {
      "timeout_seconds" => 60,
      "max_tokens_default" => 4096
    }
  end

  let(:provider) { described_class.new(config: config) }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("ANTHROPIC_API_KEY", nil).and_return("test-api-key")
    allow(ENV).to receive(:key?).and_call_original
    allow(ENV).to receive(:key?).with("ANTHROPIC_API_KEY").and_return(true)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return("test-api-key")
  end

  describe "#generate" do
    it "parses a simple text response" do
      stub_anthropic_response(
        content: [{ "type" => "text", "text" => "Hello from Claude!" }],
        usage: { "input_tokens" => 100, "output_tokens" => 25 },
        stop_reason: "end_turn"
      )

      result = provider.generate(
        messages: [{ role: "user", content: "Hi" }],
        model: "claude-haiku-4-5-20251001",
        temperature: 0.7
      )

      expect(result[:content]).to eq("Hello from Claude!")
      expect(result[:finish_reason]).to eq(:stop)
      expect(result[:usage][:prompt_tokens]).to eq(100)
      expect(result[:usage][:completion_tokens]).to eq(25)
      expect(result[:usage][:total_tokens]).to eq(125)
      expect(result[:tool_calls]).to be_empty
    end

    it "calculates cost correctly for haiku" do
      stub_anthropic_response(
        content: [{ "type" => "text", "text" => "Response" }],
        usage: { "input_tokens" => 1_000_000, "output_tokens" => 1_000_000 },
        stop_reason: "end_turn"
      )

      result = provider.generate(
        messages: [{ role: "user", content: "Hi" }],
        model: "claude-haiku-4-5-20251001"
      )

      # Haiku: input $0.80/M, output $4.00/M
      expected_cost = 0.80 + 4.00
      expect(result[:cost_usd]).to be_within(0.01).of(expected_cost)
    end

    it "calculates cost correctly for sonnet" do
      stub_anthropic_response(
        content: [{ "type" => "text", "text" => "Response" }],
        usage: { "input_tokens" => 1_000_000, "output_tokens" => 1_000_000 },
        stop_reason: "end_turn"
      )

      result = provider.generate(
        messages: [{ role: "user", content: "Hi" }],
        model: "claude-sonnet-4-5-20250929"
      )

      # Sonnet: input $3.00/M, output $15.00/M
      expected_cost = 3.00 + 15.00
      expect(result[:cost_usd]).to be_within(0.01).of(expected_cost)
    end

    it "parses tool use responses" do
      stub_anthropic_response(
        content: [
          { "type" => "text", "text" => "I'll check the time." },
          {
            "type" => "tool_use",
            "id" => "toolu_123",
            "name" => "datetime_now",
            "input" => {}
          }
        ],
        stop_reason: "tool_use"
      )

      result = provider.generate(
        messages: [{ role: "user", content: "What time is it?" }],
        model: "claude-haiku-4-5-20251001",
        tools: [{ name: "datetime_now", description: "Get time", parameters: {} }]
      )

      expect(result[:finish_reason]).to eq(:tool_use)
      expect(result[:tool_calls].size).to eq(1)
      expect(result[:tool_calls].first[:name]).to eq("datetime_now")
      expect(result[:tool_calls].first[:id]).to eq("toolu_123")
    end

    it "separates system prompt from messages" do
      messages = [
        { role: "system", content: "You are helpful." },
        { role: "user", content: "Hi" }
      ]

      captured_payload = nil
      http_response = instance_double(HTTPX::Response,
                                      status: 200,
                                      body: JSON.generate(
                                        content: [{ "type" => "text", "text" => "Hello!" }],
                                        usage: { "input_tokens" => 50, "output_tokens" => 10 },
                                        stop_reason: "end_turn"
                                      ))
      allow(http_response).to receive(:is_a?).with(HTTPX::ErrorResponse).and_return(false)

      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive(:post) do |_url, **opts|
        captured_payload = opts[:json]
        http_response
      end
      allow(HTTPX).to receive(:with).and_return(http_client)

      provider.generate(messages: messages, model: "claude-haiku-4-5-20251001")

      expect(captured_payload[:system]).to eq("You are helpful.")
      expect(captured_payload[:messages].none? { |m| m[:role] == "system" }).to be true
    end

    it "raises SecurityError without API key" do
      allow(ENV).to receive(:fetch).with("ANTHROPIC_API_KEY", nil).and_return(nil)

      expect do
        provider.generate(messages: [{ role: "user", content: "Hi" }], model: "claude-haiku-4-5-20251001")
      end.to raise_error(SecurityError, /API key not configured/)
    end

    it "raises ProviderError on connection failure" do
      error = Errno::ETIMEDOUT.new("Connection timed out")
      error_response = HTTPX::ErrorResponse.allocate
      allow(error_response).to receive(:error).and_return(error)
      allow(error_response).to receive(:is_a?).with(HTTPX::ErrorResponse).and_return(true)

      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive(:post).and_return(error_response)
      allow(HTTPX).to receive(:with).and_return(http_client)

      expect do
        provider.generate(messages: [{ role: "user", content: "Hi" }], model: "test")
      end.to raise_error(Homunculus::Agent::Models::ProviderError, /Anthropic connection error/)
    end

    it "handles max_tokens stop reason" do
      stub_anthropic_response(
        content: [{ "type" => "text", "text" => "Truncated resp..." }],
        usage: { "input_tokens" => 100, "output_tokens" => 4096 },
        stop_reason: "max_tokens"
      )

      result = provider.generate(
        messages: [{ role: "user", content: "Hi" }],
        model: "claude-haiku-4-5-20251001"
      )

      expect(result[:finish_reason]).to eq(:length)
    end
  end

  describe "#available?" do
    it "returns true when API key is set" do
      expect(provider.available?).to be true
    end

    it "returns false when API key is not set" do
      allow(ENV).to receive(:key?).with("ANTHROPIC_API_KEY").and_return(false)

      expect(provider.available?).to be false
    end
  end

  describe "#model_loaded?" do
    it "returns true when API is available" do
      expect(provider.model_loaded?("claude-haiku-4-5-20251001")).to be true
    end
  end

  # Helper to stub Anthropic Messages API
  def stub_anthropic_response(**body)
    http_response = instance_double(HTTPX::Response, status: 200, body: JSON.generate(body))
    allow(http_response).to receive(:is_a?).with(HTTPX::ErrorResponse).and_return(false)
    http_client = instance_double(HTTPX::Session)
    allow(http_client).to receive(:post).and_return(http_response)
    allow(HTTPX).to receive(:with).and_return(http_client)
  end
end
