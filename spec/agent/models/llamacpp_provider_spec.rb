# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Agent::Models::LlamaCppProvider do
  let(:config) do
    {
      "base_url" => "http://127.0.0.1:8080",
      "timeout_seconds" => 120,
      "llamacpp_options" => {}
    }
  end

  let(:provider) { described_class.new(config: config) }

  let(:messages) { [{ role: "user", content: "Hello" }] }
  let(:model)    { "mistral-7b.gguf" }

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def stub_http_client(http_client)
    allow(HTTPX).to receive(:with).and_return(http_client)
  end

  def build_http_response(status:, body:)
    response = instance_double(HTTPX::Response, status: status, body: body)
    allow(response).to receive(:is_a?).with(HTTPX::ErrorResponse).and_return(false)
    allow(response).to receive(:respond_to?).with(:status).and_return(true)
    response
  end

  def build_error_response(error)
    # Use a plain double to avoid infinite recursion when RSpec stubs is_a? on
    # an HTTPX::ErrorResponse.allocate instance (HTTPX::ErrorResponse.allocate +
    # allow(x).to receive(:is_a?) causes a SystemStackError via the interceptor).
    response = double("HTTPX::ErrorResponse") # rubocop:disable RSpec/VerifiedDoubles
    allow(response).to receive(:error).and_return(error)
    allow(response).to receive(:respond_to?).with(:status).and_return(false)
    allow(response).to receive(:respond_to?).with(:error).and_return(true)
    response
  end

  def build_http_client_for_post(status:, body:)
    http_client = instance_double(HTTPX::Session)
    allow(http_client).to receive(:post).and_return(build_http_response(status: status, body: body))
    stub_http_client(http_client)
    http_client
  end

  def build_http_client_for_get(status:, body:)
    http_client = instance_double(HTTPX::Session)
    allow(http_client).to receive(:get).and_return(build_http_response(status: status, body: body))
    stub_http_client(http_client)
    http_client
  end

  def chat_response_body(content: "Hello!", tool_calls: nil, finish_reason: "stop",
                         prompt_tokens: 50, completion_tokens: 10, id: "chatcmpl-123")
    message = { "role" => "assistant", "content" => content }
    message["tool_calls"] = tool_calls if tool_calls
    JSON.generate({
                    "id" => id,
                    "choices" => [{ "message" => message, "finish_reason" => finish_reason }],
                    "usage" => {
                      "prompt_tokens" => prompt_tokens,
                      "completion_tokens" => completion_tokens,
                      "total_tokens" => prompt_tokens + completion_tokens
                    }
                  })
  end

  # ---------------------------------------------------------------------------
  # #generate — happy path
  # ---------------------------------------------------------------------------

  describe "#generate" do
    context "with a successful text response" do
      before do
        build_http_client_for_post(status: 200,
                                   body: chat_response_body(content: "Hello!",
                                                            prompt_tokens: 50, completion_tokens: 10))
      end

      it "returns normalized content" do
        result = provider.generate(messages: messages, model: model)
        expect(result[:content]).to eq("Hello!")
      end

      it "returns zero cost_usd for local inference" do
        result = provider.generate(messages: messages, model: model)
        expect(result[:cost_usd]).to eq(0.0)
      end

      it "returns correct usage token counts" do
        result = provider.generate(messages: messages, model: model)
        expect(result[:usage][:prompt_tokens]).to eq(50)
        expect(result[:usage][:completion_tokens]).to eq(10)
        expect(result[:usage][:total_tokens]).to eq(60)
      end

      it "returns :stop finish_reason" do
        result = provider.generate(messages: messages, model: model)
        expect(result[:finish_reason]).to eq(:stop)
      end

      it "returns an empty tool_calls array" do
        result = provider.generate(messages: messages, model: model)
        expect(result[:tool_calls]).to be_empty
      end

      it "echoes back the model name" do
        result = provider.generate(messages: messages, model: model)
        expect(result[:model]).to eq(model)
      end

      it "includes metadata with the response id" do
        result = provider.generate(messages: messages, model: model)
        expect(result[:metadata][:id]).to eq("chatcmpl-123")
      end
    end

    context "with :length finish_reason" do
      it "maps it to :length" do
        build_http_client_for_post(status: 200, body: chat_response_body(finish_reason: "length"))
        result = provider.generate(messages: messages, model: model)
        expect(result[:finish_reason]).to eq(:length)
      end
    end

    # -------------------------------------------------------------------------
    # #generate — tool calls
    # -------------------------------------------------------------------------

    context "with tool_calls in the response" do
      let(:tool_calls_payload) do
        [
          {
            "id" => "call_abc123",
            "type" => "function",
            "function" => {
              "name" => "echo",
              "arguments" => '{"text":"world"}'
            }
          }
        ]
      end

      before do
        build_http_client_for_post(
          status: 200,
          body: chat_response_body(content: nil, tool_calls: tool_calls_payload, finish_reason: "tool_calls")
        )
      end

      it "returns :tool_use finish_reason" do
        result = provider.generate(messages: messages, model: model,
                                   tools: [{ name: "echo", description: "Echo", parameters: {} }])
        expect(result[:finish_reason]).to eq(:tool_use)
      end

      it "populates tool_calls with parsed function names" do
        result = provider.generate(messages: messages, model: model,
                                   tools: [{ name: "echo", description: "Echo", parameters: {} }])
        expect(result[:tool_calls].size).to eq(1)
        expect(result[:tool_calls].first[:name]).to eq("echo")
      end

      it "normalizes arguments to a symbol-keyed hash" do
        result = provider.generate(messages: messages, model: model,
                                   tools: [{ name: "echo", description: "Echo", parameters: {} }])
        expect(result[:tool_calls].first[:arguments]).to eq(text: "world")
      end

      it "preserves the tool_call id from the response" do
        result = provider.generate(messages: messages, model: model,
                                   tools: [{ name: "echo", description: "Echo", parameters: {} }])
        expect(result[:tool_calls].first[:id]).to eq("call_abc123")
      end
    end

    context "with tool_calls missing id (generates UUID)" do
      it "generates a UUID when the tool_call has no id" do
        tool_calls_payload = [{ "function" => { "name" => "echo", "arguments" => "{}" } }]
        build_http_client_for_post(
          status: 200,
          body: chat_response_body(tool_calls: tool_calls_payload, finish_reason: "tool_calls")
        )

        result = provider.generate(messages: messages, model: model)
        expect(result[:tool_calls].first[:id]).to match(/\A[0-9a-f-]{36}\z/)
      end
    end

    # -------------------------------------------------------------------------
    # #generate — error handling
    # -------------------------------------------------------------------------

    context "on connection refused" do
      it "raises ProviderError with connection error message" do
        error = Errno::ECONNREFUSED.new("Connection refused")
        error_response = build_error_response(error)
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:post).and_return(error_response)
        stub_http_client(http_client)

        expect { provider.generate(messages: messages, model: model) }
          .to raise_error(Homunculus::Agent::Models::ProviderError, /LlamaCpp connection error/)
      end
    end

    context "on HTTP 500" do
      it "raises ProviderError mentioning the status code" do
        build_http_client_for_post(status: 500, body: "Internal Server Error")

        expect { provider.generate(messages: messages, model: model) }
          .to raise_error(Homunculus::Agent::Models::ProviderError, /LlamaCpp returned 500/)
      end
    end

    context "on malformed JSON" do
      it "raises a JSON::ParserError" do
        build_http_client_for_post(status: 200, body: "not-json{{}")

        expect { provider.generate(messages: messages, model: model) }
          .to raise_error(JSON::ParserError)
      end
    end

    # -------------------------------------------------------------------------
    # #generate — payload construction
    # -------------------------------------------------------------------------

    context "when context_window is provided" do
      it "includes max_context_length in the request payload" do
        captured_payload = nil
        http_response = build_http_response(status: 200, body: chat_response_body)
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:post) do |_url, **opts|
          captured_payload = opts[:json]
          http_response
        end
        stub_http_client(http_client)

        provider.generate(messages: messages, model: model, context_window: 8192)
        expect(captured_payload[:max_context_length]).to eq(8192)
      end
    end

    context "when context_window is nil" do
      it "omits max_context_length from the request payload" do
        captured_payload = nil
        http_response = build_http_response(status: 200, body: chat_response_body)
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:post) do |_url, **opts|
          captured_payload = opts[:json]
          http_response
        end
        stub_http_client(http_client)

        provider.generate(messages: messages, model: model)
        expect(captured_payload).not_to have_key(:max_context_length)
      end
    end

    context "with grammar option" do
      it "includes grammar in the request payload" do
        captured_payload = nil
        http_response = build_http_response(status: 200, body: chat_response_body)
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:post) do |_url, **opts|
          captured_payload = opts[:json]
          http_response
        end
        stub_http_client(http_client)

        provider.generate(messages: messages, model: model, grammar: 'root ::= "yes" | "no"')
        expect(captured_payload[:grammar]).to eq('root ::= "yes" | "no"')
      end
    end

    context "with json_schema option" do
      it "sets response_format with json_schema type" do
        captured_payload = nil
        http_response = build_http_response(status: 200, body: chat_response_body)
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:post) do |_url, **opts|
          captured_payload = opts[:json]
          http_response
        end
        stub_http_client(http_client)

        schema = { type: "object", properties: { name: { type: "string" } } }
        provider.generate(messages: messages, model: model, json_schema: schema)

        expect(captured_payload[:response_format][:type]).to eq("json_schema")
        expect(captured_payload[:response_format][:json_schema]).to eq(schema)
      end
    end

    context "with sampler options" do
      it "merges sampler keys into the request payload" do
        captured_payload = nil
        http_response = build_http_response(status: 200, body: chat_response_body)
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:post) do |_url, **opts|
          captured_payload = opts[:json]
          http_response
        end
        stub_http_client(http_client)

        provider.generate(messages: messages, model: model, top_k: 40, top_p: 0.9, min_p: 0.05, repeat_penalty: 1.1)

        expect(captured_payload[:top_k]).to eq(40)
        expect(captured_payload[:top_p]).to eq(0.9)
        expect(captured_payload[:min_p]).to eq(0.05)
        expect(captured_payload[:repeat_penalty]).to eq(1.1)
      end
    end

    context "with llamacpp_options in config" do
      let(:config) do
        {
          "base_url" => "http://127.0.0.1:8080",
          "timeout_seconds" => 120,
          "llamacpp_options" => { "top_k" => 20, "repeat_penalty" => 1.05 }
        }
      end

      it "merges tier-level llamacpp_options into the request" do
        captured_payload = nil
        http_response = build_http_response(status: 200, body: chat_response_body)
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:post) do |_url, **opts|
          captured_payload = opts[:json]
          http_response
        end
        stub_http_client(http_client)

        provider.generate(messages: messages, model: model)

        expect(captured_payload[:top_k]).to eq(20)
        expect(captured_payload[:repeat_penalty]).to eq(1.05)
      end

      it "allows per-call options to override tier-level llamacpp_options" do
        captured_payload = nil
        http_response = build_http_response(status: 200, body: chat_response_body)
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:post) do |_url, **opts|
          captured_payload = opts[:json]
          http_response
        end
        stub_http_client(http_client)

        provider.generate(messages: messages, model: model, top_k: 99)
        expect(captured_payload[:top_k]).to eq(99)
      end
    end

    context "with tools defined" do
      it "includes tools array in the request payload" do
        captured_payload = nil
        http_response = build_http_response(status: 200, body: chat_response_body)
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:post) do |_url, **opts|
          captured_payload = opts[:json]
          http_response
        end
        stub_http_client(http_client)

        tools = [{ name: "echo", description: "Echoes text", parameters: { type: "object" } }]
        provider.generate(messages: messages, model: model, tools: tools)

        expect(captured_payload[:tools]).to be_an(Array)
        expect(captured_payload[:tools].first[:type]).to eq("function")
        expect(captured_payload[:tools].first[:function][:name]).to eq("echo")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #generate_stream
  # ---------------------------------------------------------------------------

  describe "#generate_stream" do
    def build_stream_response(lines:, status: 200)
      # HTTPX::StreamResponse does not have a :status method, so we cannot use
      # instance_double(HTTPX::StreamResponse). We use a plain double that
      # mimics the interface the implementation actually calls on the response.
      response = double("stream_response") # rubocop:disable RSpec/VerifiedDoubles
      allow(response).to receive(:status).and_return(status)
      allow(response).to receive(:respond_to?).with(:status).and_return(true)
      allow(response).to receive(:is_a?).with(HTTPX::ErrorResponse).and_return(false)
      allow(response).to receive(:each_line) do |&block|
        lines.each { |line| block.call(line) }
      end
      response
    end

    def sse_chunk(content: nil, tool_calls: nil, usage: nil, finish_reason: nil)
      delta = {}
      delta["content"] = content if content
      delta["tool_calls"] = tool_calls if tool_calls
      choice = { "delta" => delta }
      choice["finish_reason"] = finish_reason if finish_reason
      body = { "choices" => [choice] }
      body["usage"] = usage if usage
      "data: #{JSON.generate(body)}"
    end

    def sse_done
      "data: [DONE]"
    end

    def stub_stream_client(response)
      stream_session = instance_double(HTTPX::Session)
      allow(stream_session).to receive(:post).and_return(response)
      plugin_session = instance_double(HTTPX::Session)
      allow(plugin_session).to receive(:with).and_return(stream_session)
      allow(HTTPX).to receive(:plugin).with(:stream).and_return(plugin_session)
    end

    context "with a simple text stream" do
      let(:sse_lines) do
        [
          sse_chunk(content: "Hello"),
          sse_chunk(content: ", world!"),
          sse_done
        ]
      end

      before do
        stub_stream_client(build_stream_response(lines: sse_lines))
      end

      it "yields each text chunk to the block" do
        chunks = []
        provider.generate_stream(messages: messages, model: model) { |chunk| chunks << chunk }
        expect(chunks).to eq(["Hello", ", world!"])
      end

      it "returns aggregated content in the result hash" do
        result = provider.generate_stream(messages: messages, model: model)
        expect(result[:content]).to eq("Hello, world!")
      end

      it "returns :stop finish_reason" do
        result = provider.generate_stream(messages: messages, model: model)
        expect(result[:finish_reason]).to eq(:stop)
      end

      it "returns 0.0 cost_usd" do
        result = provider.generate_stream(messages: messages, model: model)
        expect(result[:cost_usd]).to eq(0.0)
      end

      it "returns empty tool_calls" do
        result = provider.generate_stream(messages: messages, model: model)
        expect(result[:tool_calls]).to be_empty
      end
    end

    context "with usage data in the stream" do
      let(:sse_lines) do
        [
          sse_chunk(content: "Hi"),
          sse_chunk(usage: { "prompt_tokens" => 20, "completion_tokens" => 5, "total_tokens" => 25 }),
          sse_done
        ]
      end

      before { stub_stream_client(build_stream_response(lines: sse_lines)) }

      it "returns usage token counts from the stream" do
        result = provider.generate_stream(messages: messages, model: model)
        expect(result[:usage][:prompt_tokens]).to eq(20)
        expect(result[:usage][:completion_tokens]).to eq(5)
        expect(result[:usage][:total_tokens]).to eq(25)
      end
    end

    context "with tool call deltas in the stream" do
      let(:tool_call_delta) do
        [
          {
            "id" => "call_xyz",
            "type" => "function",
            "function" => { "name" => "datetime_now", "arguments" => "{}" }
          }
        ]
      end

      let(:sse_lines) do
        [
          sse_chunk(tool_calls: tool_call_delta),
          sse_done
        ]
      end

      before { stub_stream_client(build_stream_response(lines: sse_lines)) }

      it "returns :tool_use finish_reason when tool_calls are present" do
        result = provider.generate_stream(messages: messages, model: model)
        expect(result[:finish_reason]).to eq(:tool_use)
      end

      it "populates tool_calls from stream deltas" do
        result = provider.generate_stream(messages: messages, model: model)
        expect(result[:tool_calls].size).to eq(1)
        expect(result[:tool_calls].first[:name]).to eq("datetime_now")
        expect(result[:tool_calls].first[:id]).to eq("call_xyz")
      end

      it "returns nil content when only tool_calls are streamed" do
        result = provider.generate_stream(messages: messages, model: model)
        expect(result[:content]).to be_nil
      end
    end

    context "with malformed SSE chunk" do
      let(:sse_lines) do
        [
          sse_chunk(content: "Good"),
          "data: {bad json",
          sse_chunk(content: " output"),
          sse_done
        ]
      end

      before { stub_stream_client(build_stream_response(lines: sse_lines)) }

      it "skips malformed chunks and aggregates valid content" do
        result = provider.generate_stream(messages: messages, model: model)
        expect(result[:content]).to eq("Good output")
      end
    end

    context "with non-data SSE lines" do
      let(:sse_lines) do
        [
          "",
          "event: ping",
          sse_chunk(content: "Hello"),
          sse_done
        ]
      end

      before { stub_stream_client(build_stream_response(lines: sse_lines)) }

      it "ignores non-data lines and yields only content chunks" do
        chunks = []
        provider.generate_stream(messages: messages, model: model) { |chunk| chunks << chunk }
        expect(chunks).to eq(["Hello"])
      end
    end

    context "on HTTP 500 from stream endpoint" do
      it "raises ProviderError" do
        response = double("stream_response") # rubocop:disable RSpec/VerifiedDoubles
        allow(response).to receive(:respond_to?).with(:status).and_return(true)
        allow(response).to receive(:is_a?).with(HTTPX::ErrorResponse).and_return(false)
        allow(response).to receive_messages(status: 500, body: "Internal Error")
        stub_stream_client(response)

        expect { provider.generate_stream(messages: messages, model: model) }
          .to raise_error(Homunculus::Agent::Models::ProviderError, /LlamaCpp returned 500/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #available?
  # ---------------------------------------------------------------------------

  describe "#available?" do
    context "when server responds with 200 and status:ok" do
      it "returns true" do
        http_response = build_http_response(status: 200, body: '{"status":"ok"}')
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:get).and_return(http_response)
        stub_http_client(http_client)

        expect(provider.available?).to be(true)
      end
    end

    context "when server responds with non-200" do
      it "returns false" do
        http_response = instance_double(HTTPX::Response, status: 503)
        allow(http_response).to receive(:respond_to?).with(:status).and_return(true)
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:get).and_return(http_response)
        stub_http_client(http_client)

        expect(provider.available?).to be(false)
      end
    end

    context "when connection is refused" do
      it "returns false" do
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:get).and_raise(StandardError, "connection refused")
        stub_http_client(http_client)

        expect(provider.available?).to be(false)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #model_loaded?
  # ---------------------------------------------------------------------------

  describe "#model_loaded?" do
    let(:models_response_body) do
      JSON.generate({
                      "data" => [
                        { "id" => "mistral-7b.gguf", "object" => "model" }
                      ]
                    })
    end

    context "when model is present in /v1/models" do
      it "returns true for an exact match" do
        build_http_client_for_get(status: 200, body: models_response_body)
        expect(provider.model_loaded?("mistral-7b.gguf")).to be(true)
      end

      it "returns true for a partial match" do
        build_http_client_for_get(status: 200, body: models_response_body)
        expect(provider.model_loaded?("mistral-7b")).to be(true)
      end
    end

    context "when model is not in /v1/models" do
      it "returns false" do
        build_http_client_for_get(status: 200, body: models_response_body)
        expect(provider.model_loaded?("llama-3.gguf")).to be(false)
      end
    end

    context "when model_name is nil and at least one model is loaded" do
      it "returns true" do
        build_http_client_for_get(status: 200, body: models_response_body)
        expect(provider.model_loaded?(nil)).to be(true)
      end
    end

    context "when model_name is nil and no models are loaded" do
      it "returns false" do
        build_http_client_for_get(status: 200, body: JSON.generate({ "data" => [] }))
        expect(provider.model_loaded?(nil)).to be(false)
      end
    end

    context "when server returns non-200" do
      it "returns false" do
        http_response = instance_double(HTTPX::Response, status: 503)
        allow(http_response).to receive(:respond_to?).with(:status).and_return(true)
        allow(http_response).to receive(:is_a?).with(HTTPX::ErrorResponse).and_return(false)
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:get).and_return(http_response)
        stub_http_client(http_client)

        expect(provider.model_loaded?("mistral-7b.gguf")).to be(false)
      end
    end

    context "when connection fails" do
      it "returns false" do
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:get).and_raise(StandardError, "timeout")
        stub_http_client(http_client)

        expect(provider.model_loaded?("mistral-7b.gguf")).to be(false)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #preload_model
  # ---------------------------------------------------------------------------

  describe "#preload_model" do
    it "returns a sentinel hash without making any HTTP calls" do
      http_client = instance_double(HTTPX::Session)
      # No HTTP stub — any HTTP call here would raise due to strict doubles
      stub_http_client(http_client)

      result = provider.preload_model("mistral-7b.gguf")

      expect(result[:loaded]).to be(true)
      expect(result[:elapsed_ms]).to eq(0)
      expect(result[:note]).to match(/startup/)
    end

    it "completes without making any HTTP call" do
      http_client = instance_double(HTTPX::Session)
      stub_http_client(http_client)

      expect { provider.preload_model("mistral-7b.gguf") }.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------
  # Configuration defaults
  # ---------------------------------------------------------------------------

  describe "configuration" do
    context "when base_url is not specified" do
      let(:config) { { "timeout_seconds" => 60 } }

      it "defaults to http://127.0.0.1:8080" do
        captured_url = nil
        http_response = build_http_response(status: 200, body: chat_response_body)
        http_client = instance_double(HTTPX::Session)
        allow(http_client).to receive(:post) do |url, **_opts|
          captured_url = url
          http_response
        end
        stub_http_client(http_client)

        provider.generate(messages: messages, model: model)
        expect(captured_url).to start_with("http://127.0.0.1:8080")
      end
    end

    context "when timeout_seconds is not specified" do
      let(:config) { { "base_url" => "http://127.0.0.1:8080" } }

      it "uses DEFAULT_TIMEOUT of 120 seconds without raising" do
        build_http_client_for_post(status: 200, body: chat_response_body)
        expect { provider.generate(messages: messages, model: model) }.not_to raise_error
      end
    end
  end
end
