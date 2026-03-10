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

  describe "#preload_model" do
    let(:model) { "qwen2.5:14b" }
    let(:success_body) do
      {
        "model" => model,
        "message" => { "role" => "assistant", "content" => "Hi" },
        "done" => true,
        "total_duration" => 5_000_000_000,
        "load_duration" => 3_000_000_000,
        "prompt_eval_count" => 1,
        "eval_count" => 1
      }
    end

    it "sends a minimal chat request and returns timing metrics" do
      stub_request(:post, "http://localhost:11434/api/chat")
        .with(body: hash_including("model" => model, "stream" => false))
        .to_return(status: 200, body: JSON.generate(success_body),
                   headers: { "Content-Type" => "application/json" })

      result = provider.preload_model(model)

      expect(result[:loaded]).to be(true)
      expect(result[:elapsed_ms]).to be_a(Integer)
      expect(result[:load_duration_ns]).to eq(3_000_000_000)
      expect(result[:total_duration_ns]).to eq(5_000_000_000)
    end

    it "sends num_predict: 1 and temperature: 0 to minimize work" do
      req = stub_request(:post, "http://localhost:11434/api/chat")
            .with(body: hash_including("options" => { "num_predict" => 1, "temperature" => 0 }))
            .to_return(status: 200, body: JSON.generate(success_body),
                       headers: { "Content-Type" => "application/json" })

      provider.preload_model(model)
      expect(req).to have_been_requested
    end

    it "includes keep_alive in the payload" do
      req = stub_request(:post, "http://localhost:11434/api/chat")
            .with(body: hash_including("keep_alive" => "30m"))
            .to_return(status: 200, body: JSON.generate(success_body),
                       headers: { "Content-Type" => "application/json" })

      provider.preload_model(model)
      expect(req).to have_been_requested
    end

    it "raises ProviderError on non-200 status" do
      stub_request(:post, "http://localhost:11434/api/chat")
        .to_return(status: 500, body: "Internal Server Error")

      expect { provider.preload_model(model) }
        .to raise_error(Homunculus::Agent::Models::ProviderError, /preload returned 500/)
    end

    it "raises ProviderError on connection error" do
      error = Errno::ECONNREFUSED.new("Connection refused")
      error_response = HTTPX::ErrorResponse.allocate
      allow(error_response).to receive(:error).and_return(error)
      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive(:post).and_return(error_response)
      allow(HTTPX).to receive(:with).and_return(http_client)

      expect { provider.preload_model(model) }
        .to raise_error(Homunculus::Agent::Models::ProviderError, /connection error/)
    end
  end
end
