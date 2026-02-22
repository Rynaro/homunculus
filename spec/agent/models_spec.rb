# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Agent::ModelProvider do
  describe "Data types" do
    describe "Response" do
      it "holds completion data" do
        response = described_class::Response.new(
          content: "Hello",
          tool_calls: nil,
          usage: described_class::TokenUsage.new(input_tokens: 10, output_tokens: 5),
          model: "test",
          stop_reason: "end_turn",
          raw_response: {}
        )

        expect(response.content).to eq("Hello")
        expect(response.stop_reason).to eq("end_turn")
        expect(response.tool_calls).to be_nil
      end
    end

    describe "ToolCall" do
      it "holds tool call data" do
        tc = described_class::ToolCall.new(
          id: "123", name: "echo", arguments: { text: "hi" }
        )

        expect(tc.id).to eq("123")
        expect(tc.name).to eq("echo")
        expect(tc.arguments).to eq({ text: "hi" })
      end
    end

    describe "TokenUsage" do
      it "holds token counts" do
        usage = described_class::TokenUsage.new(input_tokens: 100, output_tokens: 50)

        expect(usage.input_tokens).to eq(100)
        expect(usage.output_tokens).to eq(50)
      end
    end
  end

  describe "#complete" do
    let(:ollama_config) do
      Homunculus::ModelConfig.new(
        provider: "ollama",
        base_url: "http://localhost:11434",
        default_model: "qwen2.5:14b",
        context_window: 32_768,
        temperature: 0.7
      )
    end

    let(:anthropic_config) do
      Homunculus::ModelConfig.new(
        provider: "anthropic",
        model: "claude-sonnet-4-20250514",
        context_window: 200_000,
        temperature: 0.3,
        api_key: "test-key"
      )
    end

    context "with Ollama provider" do
      let(:provider) { described_class.new(ollama_config) }

      it "parses a simple text response" do
        stub_ollama_response(
          message: { "role" => "assistant", "content" => "Hello!" },
          prompt_eval_count: 50,
          eval_count: 10
        )

        response = provider.complete(
          messages: [{ role: "user", content: "Hi" }],
          system: "You are helpful."
        )

        expect(response.content).to eq("Hello!")
        expect(response.stop_reason).to eq("end_turn")
        expect(response.usage.input_tokens).to eq(50)
        expect(response.usage.output_tokens).to eq(10)
        expect(response.tool_calls).to be_nil
      end

      it "parses tool call responses" do
        stub_ollama_response(
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
          }
        )

        response = provider.complete(
          messages: [{ role: "user", content: "Echo world" }],
          tools: [{ name: "echo", description: "Echo text", parameters: {} }]
        )

        expect(response.stop_reason).to eq("tool_use")
        expect(response.tool_calls.size).to eq(1)
        expect(response.tool_calls.first.name).to eq("echo")
        expect(response.tool_calls.first.arguments[:text]).to eq("world")
      end

      it "raises a clear error when Ollama returns an ErrorResponse" do
        error = Errno::ECONNREFUSED.new("Connection refused - connect(2) for 127.0.0.1:11434")
        error_response = HTTPX::ErrorResponse.allocate
        allow(error_response).to receive(:error).and_return(error)
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:post).and_return(error_response)
        allow(HTTPX).to receive(:with).and_return(http_client)

        expect do
          provider.complete(messages: [{ role: "user", content: "Hi" }])
        end.to raise_error(RuntimeError, /Ollama connection error.*Connection refused/)
      end

      def stub_ollama_response(**body)
        http_response = instance_double(HTTPX::Response, status: 200, body: JSON.generate(body))
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:post).and_return(http_response)
        allow(HTTPX).to receive(:with).and_return(http_client)
      end
    end

    context "with Anthropic provider" do
      let(:provider) { described_class.new(anthropic_config) }

      it "parses a simple text response" do
        stub_anthropic_response(
          content: [{ "type" => "text", "text" => "Hello!" }],
          usage: { "input_tokens" => 100, "output_tokens" => 25 },
          stop_reason: "end_turn"
        )

        response = provider.complete(
          messages: [{ role: "user", content: "Hi" }],
          system: "You are helpful."
        )

        expect(response.content).to eq("Hello!")
        expect(response.stop_reason).to eq("end_turn")
        expect(response.usage.input_tokens).to eq(100)
        expect(response.usage.output_tokens).to eq(25)
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

        response = provider.complete(
          messages: [{ role: "user", content: "What time is it?" }],
          tools: [{ name: "datetime_now", description: "Get time", parameters: {} }]
        )

        expect(response.stop_reason).to eq("tool_use")
        expect(response.tool_calls.size).to eq(1)
        expect(response.tool_calls.first.name).to eq("datetime_now")
        expect(response.tool_calls.first.id).to eq("toolu_123")
      end

      it "raises a clear error when Anthropic returns an ErrorResponse" do
        error = Errno::ETIMEDOUT.new("Connection timed out")
        error_response = HTTPX::ErrorResponse.allocate
        allow(error_response).to receive(:error).and_return(error)
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:post).and_return(error_response)
        allow(HTTPX).to receive(:with).and_return(http_client)

        expect do
          provider.complete(messages: [{ role: "user", content: "Hi" }])
        end.to raise_error(RuntimeError, /Anthropic connection error.*timed out/)
      end

      it "raises without API key" do
        keyless_config = Homunculus::ModelConfig.new(
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          context_window: 200_000,
          temperature: 0.3
        )
        provider = described_class.new(keyless_config)

        allow(ENV).to receive(:fetch).with("ANTHROPIC_API_KEY", nil).and_return(nil)

        expect do
          provider.complete(messages: [{ role: "user", content: "Hi" }])
        end.to raise_error(SecurityError, /API key not configured/)
      end

      def stub_anthropic_response(**body)
        http_response = instance_double(HTTPX::Response, status: 200, body: JSON.generate(body))
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:post).and_return(http_response)
        allow(HTTPX).to receive(:with).and_return(http_client)
      end
    end

    context "with unknown provider" do
      it "raises ArgumentError" do
        bad_config = Homunculus::ModelConfig.new(
          provider: "unknown",
          context_window: 1000,
          temperature: 0.5
        )
        provider = described_class.new(bad_config)

        expect do
          provider.complete(messages: [{ role: "user", content: "Hi" }])
        end.to raise_error(ArgumentError, /Unknown provider/)
      end
    end
  end
end
