# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Agent::Models::OllamaProvider do
  let(:config) do
    {
      "base_url" => "http://localhost:11434",
      "keep_alive" => "30m",
      "timeout_seconds" => 120
    }
  end

  let(:provider) { described_class.new(config: config) }

  describe "#generate" do
    it "parses a simple text response" do
      stub_ollama_chat(
        message: { "role" => "assistant", "content" => "Hello!" },
        prompt_eval_count: 50,
        eval_count: 10,
        done: true
      )

      result = provider.generate(
        messages: [{ role: "user", content: "Hi" }],
        model: "homunculus-workhorse",
        temperature: 0.7,
        max_tokens: 4096
      )

      expect(result[:content]).to eq("Hello!")
      expect(result[:finish_reason]).to eq(:stop)
      expect(result[:usage][:prompt_tokens]).to eq(50)
      expect(result[:usage][:completion_tokens]).to eq(10)
      expect(result[:usage][:total_tokens]).to eq(60)
      expect(result[:cost_usd]).to eq(0.0)
      expect(result[:tool_calls]).to be_empty
    end

    it "parses tool call responses" do
      stub_ollama_chat(
        message: {
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            {
              "function" => {
                "name" => "echo",
                "arguments" => { "text" => "world" }
              }
            }
          ]
        },
        prompt_eval_count: 30,
        eval_count: 5
      )

      result = provider.generate(
        messages: [{ role: "user", content: "Echo world" }],
        model: "homunculus-workhorse",
        tools: [{ name: "echo", description: "Echo text", parameters: {} }]
      )

      expect(result[:finish_reason]).to eq(:tool_use)
      expect(result[:tool_calls].size).to eq(1)
      expect(result[:tool_calls].first[:name]).to eq("echo")
      expect(result[:tool_calls].first[:arguments][:text]).to eq("world")
      expect(result[:tool_calls].first[:id]).to be_a(String) # UUID generated
    end

    it "raises ProviderError on connection failure" do
      error = Errno::ECONNREFUSED.new("Connection refused")
      error_response = HTTPX::ErrorResponse.allocate
      allow(error_response).to receive(:error).and_return(error)
      allow(error_response).to receive(:is_a?).with(HTTPX::ErrorResponse).and_return(true)

      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive(:post).and_return(error_response)
      allow(HTTPX).to receive(:with).and_return(http_client)

      expect do
        provider.generate(messages: [{ role: "user", content: "Hi" }], model: "test")
      end.to raise_error(Homunculus::Agent::Models::ProviderError, /Ollama connection error/)
    end

    it "raises ProviderError on non-200 status" do
      http_response = instance_double(HTTPX::Response, status: 500, body: "Internal error")
      allow(http_response).to receive(:is_a?).with(HTTPX::ErrorResponse).and_return(false)
      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive(:post).and_return(http_response)
      allow(HTTPX).to receive(:with).and_return(http_client)

      expect do
        provider.generate(messages: [{ role: "user", content: "Hi" }], model: "test")
      end.to raise_error(Homunculus::Agent::Models::ProviderError, /Ollama returned 500/)
    end

    it "includes num_ctx in options when context_window is provided" do
      captured_payload = nil
      http_response = instance_double(HTTPX::Response, status: 200,
                                                       body: JSON.generate(message: { "role" => "assistant", "content" => "OK" }))
      allow(http_response).to receive(:is_a?).with(HTTPX::ErrorResponse).and_return(false)

      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive(:post) do |_url, **opts|
        captured_payload = opts[:json]
        http_response
      end
      allow(HTTPX).to receive(:with).and_return(http_client)

      provider.generate(messages: [{ role: "user", content: "Hi" }], model: "test", context_window: 16_384)

      expect(captured_payload[:options][:num_ctx]).to eq(16_384)
    end

    it "omits num_ctx from options when context_window is nil" do
      captured_payload = nil
      http_response = instance_double(HTTPX::Response, status: 200,
                                                       body: JSON.generate(message: { "role" => "assistant", "content" => "OK" }))
      allow(http_response).to receive(:is_a?).with(HTTPX::ErrorResponse).and_return(false)

      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive(:post) do |_url, **opts|
        captured_payload = opts[:json]
        http_response
      end
      allow(HTTPX).to receive(:with).and_return(http_client)

      provider.generate(messages: [{ role: "user", content: "Hi" }], model: "test")

      expect(captured_payload[:options]).not_to have_key(:num_ctx)
    end

    it "includes keep_alive in the payload" do
      captured_payload = nil
      http_response = instance_double(HTTPX::Response, status: 200,
                                                       body: JSON.generate(message: { "role" => "assistant", "content" => "OK" }))
      allow(http_response).to receive(:is_a?).with(HTTPX::ErrorResponse).and_return(false)

      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive(:post) do |_url, **opts|
        captured_payload = opts[:json]
        http_response
      end
      allow(HTTPX).to receive(:with).and_return(http_client)

      provider.generate(messages: [{ role: "user", content: "Hi" }], model: "test")

      expect(captured_payload[:keep_alive]).to eq("30m")
    end
  end

  describe "#available?" do
    it "returns true when Ollama responds with 200" do
      http_response = instance_double(HTTPX::Response, status: 200, body: '{"models":[]}')
      allow(http_response).to receive(:is_a?).with(HTTPX::ErrorResponse).and_return(false)
      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive(:get).and_return(http_response)
      allow(HTTPX).to receive(:with).and_return(http_client)

      expect(provider.available?).to be true
    end

    it "returns false when Ollama is unreachable" do
      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive(:get).and_raise(StandardError, "connection refused")
      allow(HTTPX).to receive(:with).and_return(http_client)

      expect(provider.available?).to be false
    end
  end

  describe "#model_loaded?" do
    it "returns true when model is available" do
      http_response = instance_double(HTTPX::Response, status: 200, body: '{"modelfile":"..."}')
      allow(http_response).to receive(:is_a?).with(HTTPX::ErrorResponse).and_return(false)
      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive(:post).and_return(http_response)
      allow(HTTPX).to receive(:with).and_return(http_client)

      expect(provider.model_loaded?("homunculus-workhorse")).to be true
    end

    it "returns false when model is not found" do
      http_response = instance_double(HTTPX::Response, status: 404, body: "not found")
      allow(http_response).to receive(:is_a?).with(HTTPX::ErrorResponse).and_return(false)
      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive(:post).and_return(http_response)
      allow(HTTPX).to receive(:with).and_return(http_client)

      expect(provider.model_loaded?("nonexistent")).to be false
    end
  end

  describe "#list_models" do
    it "returns a list of model names" do
      response_body = JSON.generate({
                                      "models" => [
                                        { "name" => "homunculus-workhorse", "size" => 8_000_000 },
                                        { "name" => "homunculus-coder", "size" => 8_000_000 }
                                      ]
                                    })
      http_response = instance_double(HTTPX::Response, status: 200, body: response_body)
      allow(http_response).to receive(:is_a?).with(HTTPX::ErrorResponse).and_return(false)
      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive(:get).and_return(http_response)
      allow(HTTPX).to receive(:with).and_return(http_client)

      models = provider.list_models
      expect(models).to eq(%w[homunculus-workhorse homunculus-coder])
    end
  end

  # Helper to stub Ollama chat endpoint
  def stub_ollama_chat(**body)
    http_response = instance_double(HTTPX::Response, status: 200, body: JSON.generate(body))
    allow(http_response).to receive(:is_a?).with(HTTPX::ErrorResponse).and_return(false)
    http_client = instance_double(HTTPX::Session)
    allow(http_client).to receive(:post).and_return(http_response)
    allow(HTTPX).to receive(:with).and_return(http_client)
  end
end
