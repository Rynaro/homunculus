# frozen_string_literal: true

require "json"
require "httpx"
require_relative "../../utils/argument_normalizer"
require_relative "../../utils/http_error_handling"

module Homunculus
  module Agent
    module Models
      # Anthropic Claude API client for cloud escalation.
      # Uses HTTPX for HTTP calls to maintain control over tool call handling.
      # API key is read from ENV["ANTHROPIC_API_KEY"] at runtime — never stored.
      class AnthropicProvider < Provider
        include Utils::ArgumentNormalizer
        include Utils::HttpErrorHandling

        API_URL = "https://api.anthropic.com/v1/messages"
        API_VERSION = "2023-06-01"
        DEFAULT_TIMEOUT = 60
        MAX_RETRIES = 3

        # Pricing per 1M tokens (input, output) in USD
        PRICING = {
          "claude-haiku-4-5-20251001" => { input: 0.80, output: 4.00 },
          "claude-sonnet-4-5-20250929" => { input: 3.00, output: 15.00 },
          "claude-opus-4-6" => { input: 15.00, output: 75.00 }
        }.freeze

        def initialize(config:)
          super(name: :anthropic, config: config)
          @timeout = config.fetch("timeout_seconds", DEFAULT_TIMEOUT)
          @max_tokens_default = config.fetch("max_tokens_default", 4096)
        end

        # Synchronous completion via Anthropic Messages API.
        # Separates system prompt from messages per Anthropic's format.
        def generate(messages:, model:, tools: nil, temperature: 0.7, max_tokens: 4096, context_window: nil)
          api_key = fetch_api_key!
          system_content, formatted_messages = separate_system_prompt(messages)

          payload = build_payload(
            model:, messages: formatted_messages, system: system_content,
            tools:, temperature:, max_tokens:
          )

          @logger.debug("Anthropic request", model:, message_count: messages.size, tools: tools&.size || 0)
          start_time = monotonic_ms

          http_response = request_with_retry(payload, api_key)
          elapsed = monotonic_ms - start_time

          parsed = JSON.parse(http_response.body.to_s)
          result = parse_response(parsed, model)

          @logger.info("Anthropic response",
                       model:, latency_ms: elapsed.round,
                       tokens_in: result[:usage][:prompt_tokens],
                       tokens_out: result[:usage][:completion_tokens],
                       cost_usd: result[:cost_usd].round(6),
                       finish_reason: result[:finish_reason])

          result
        end

        # Streaming completion. Yields text chunks and returns aggregated result.
        # Uses Anthropic's streaming format (SSE with event types).
        def generate_stream(messages:, model:, tools: nil, temperature: 0.7, max_tokens: 4096, context_window: nil, &)
          api_key = fetch_api_key!
          system_content, formatted_messages = separate_system_prompt(messages)

          payload = build_payload(
            model:, messages: formatted_messages, system: system_content,
            tools:, temperature:, max_tokens:, stream: true
          )

          @logger.debug("Anthropic stream request", model:, message_count: messages.size)

          http_response = authenticated_client(api_key)
                          .post(API_URL, json: payload)

          raise_if_error!(http_response)

          unless http_response.status == 200
            raise ProviderError, "Anthropic stream returned #{http_response.status}: #{http_response.body}"
          end

          parse_stream_response(http_response, model, &)
        end

        # Lightweight reachability check — verifies we have an API key
        # and can reach the API (doesn't consume tokens).
        def available?
          ENV.key?("ANTHROPIC_API_KEY") && !ENV["ANTHROPIC_API_KEY"].to_s.strip.empty?
        end

        # Anthropic models are always "loaded" if the API is reachable.
        def model_loaded?(_model)
          available?
        end

        # Accumulator for SSE stream parsing state.
        StreamState = Struct.new(:content, :tool_calls, :usage_data, :current_tool, keyword_init: true)
        private_constant :StreamState

        private

        def fetch_api_key!
          key = ENV.fetch("ANTHROPIC_API_KEY", nil)
          raise SecurityError, "Anthropic API key not configured (set ANTHROPIC_API_KEY env var)" unless key

          key
        end

        def build_payload(model:, messages:, temperature:, max_tokens:, system: nil, tools: nil, stream: false)
          payload = {
            model: model,
            max_tokens: max_tokens,
            temperature: temperature,
            messages: messages
          }

          payload[:system] = system if system
          payload[:tools] = tools.map { |t| format_tool(t) } if tools&.any?
          payload[:stream] = true if stream
          payload
        end

        # Extracts system prompt from the first message if role is "system".
        # Anthropic requires system to be a separate parameter.
        def separate_system_prompt(messages)
          return [nil, format_messages(messages)] if messages.empty?

          if messages.first[:role].to_s == "system"
            system = messages.first[:content].to_s
            [system, format_messages(messages[1..])]
          else
            [nil, format_messages(messages)]
          end
        end

        def format_messages(messages)
          formatted = []

          messages.each do |msg|
            role = msg[:role].to_s
            case role
            when "tool"
              if formatted.last && formatted.last[:role] == "user" &&
                 formatted.last[:content].is_a?(Array) &&
                 formatted.last[:content].last&.dig(:type) == "tool_result"
                formatted.last[:content] << {
                  type: "tool_result",
                  tool_use_id: msg[:tool_call_id],
                  content: msg[:content].to_s
                }
              else
                formatted << {
                  role: "user",
                  content: [
                    {
                      type: "tool_result",
                      tool_use_id: msg[:tool_call_id],
                      content: msg[:content].to_s
                    }
                  ]
                }
              end
            when "assistant"
              content_blocks = []
              content_blocks << { type: "text", text: msg[:content] } if msg[:content] && !msg[:content].to_s.empty?

              msg[:tool_calls]&.each do |tc|
                content_blocks << {
                  type: "tool_use",
                  id: tc.is_a?(Hash) ? tc[:id] : tc.id,
                  name: tc.is_a?(Hash) ? tc[:name] : tc.name,
                  input: tc.is_a?(Hash) ? tc[:arguments] : tc.arguments
                }
              end

              formatted << { role: "assistant", content: content_blocks }
            when "user"
              formatted << { role: "user", content: msg[:content].to_s }
            when "system"
              next # System prompt handled separately
            end
          end

          formatted
        end

        def format_tool(tool_def)
          params = tool_def[:parameters] || {}
          {
            name: tool_def[:name],
            description: tool_def[:description],
            input_schema: params
          }
        end

        def parse_response(parsed, model)
          content_blocks = parsed["content"] || []
          text_content = content_blocks
                         .select { |b| b["type"] == "text" }
                         .map { |b| b["text"] }
                         .join

          tool_calls = content_blocks
                       .select { |b| b["type"] == "tool_use" }
                       .map do |tc|
                         {
                           id: tc["id"],
                           name: tc["name"],
                           arguments: normalize_arguments(tc["input"])
                         }
          end

          usage_data = parsed["usage"] || {}
          input_tokens = usage_data["input_tokens"] || 0
          output_tokens = usage_data["output_tokens"] || 0

          finish_reason = case parsed["stop_reason"]
                          when "tool_use" then :tool_use
                          when "max_tokens" then :length
                          else :stop
                          end

          {
            content: text_content.empty? ? nil : text_content,
            tool_calls: tool_calls,
            model: model,
            usage: {
              prompt_tokens: input_tokens,
              completion_tokens: output_tokens,
              total_tokens: input_tokens + output_tokens
            },
            finish_reason: finish_reason,
            cost_usd: calculate_cost(model, input_tokens, output_tokens),
            metadata: {
              stop_reason: parsed["stop_reason"],
              id: parsed["id"]
            }
          }
        end

        def parse_stream_response(http_response, model, &)
          state = StreamState.new(content: +"", tool_calls: [], usage_data: {}, current_tool: nil)

          http_response.body.to_s.each_line do |line|
            parse_sse_line(line.strip, state, &)
          rescue JSON::ParserError
            next
          end

          build_stream_result(state, model)
        end

        def parse_sse_line(line, state, &)
          return if line.empty? || line.start_with?("event:")
          return unless line.start_with?("data: ")

          data = line.delete_prefix("data: ")
          return if data == "[DONE]"

          process_stream_event(JSON.parse(data), state, &)
        end

        def process_stream_event(event, state, &)
          case event["type"]
          when "content_block_delta"
            handle_content_delta(event["delta"] || {}, state, &)
          when "content_block_start"
            handle_block_start(event["content_block"] || {}, state)
          when "content_block_stop"
            finalize_tool_call(state)
          when "message_delta"
            state.usage_data.merge!(event["usage"] || {})
          when "message_start"
            state.usage_data.merge!(event.dig("message", "usage") || {})
          end
        end

        def handle_content_delta(delta, state, &block)
          if delta["type"] == "text_delta" && delta["text"]
            state.content << delta["text"]
            block&.call(delta["text"])
          elsif delta["type"] == "input_json_delta" && state.current_tool
            state.current_tool[:raw_json] << (delta["partial_json"] || "")
          end
        end

        def handle_block_start(content_block, state)
          return unless content_block["type"] == "tool_use"

          state.current_tool = { id: content_block["id"], name: content_block["name"], raw_json: +"" }
        end

        def finalize_tool_call(state)
          return unless state.current_tool

          raw = state.current_tool[:raw_json].to_s
          args = raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)
          state.tool_calls << { id: state.current_tool[:id], name: state.current_tool[:name], arguments: args }
          state.current_tool = nil
        end

        def build_stream_result(state, model)
          input_tokens = state.usage_data["input_tokens"] || 0
          output_tokens = state.usage_data["output_tokens"] || 0

          {
            content: state.content.empty? ? nil : state.content,
            tool_calls: state.tool_calls,
            model: model,
            usage: { prompt_tokens: input_tokens, completion_tokens: output_tokens,
                     total_tokens: input_tokens + output_tokens },
            finish_reason: state.tool_calls.any? ? :tool_use : :stop,
            cost_usd: calculate_cost(model, input_tokens, output_tokens),
            metadata: {}
          }
        end

        def calculate_cost(model, input_tokens, output_tokens)
          pricing = PRICING[model]
          return 0.0 unless pricing

          input_cost = (input_tokens.to_f / 1_000_000) * pricing[:input]
          output_cost = (output_tokens.to_f / 1_000_000) * pricing[:output]
          input_cost + output_cost
        end

        def request_with_retry(payload, api_key)
          retries = 0

          loop do
            response = authenticated_client(api_key).post(API_URL, json: payload)

            raise_if_error!(response)
            return response if response.status == 200

            if response.status == 429 && retries < MAX_RETRIES
              retries += 1
              wait_time = (2**retries) + rand(0.0..1.0)
              @logger.warn("Anthropic rate limited (429), retrying",
                           retry: retries, wait_seconds: wait_time.round(1))
              sleep(wait_time)
              next
            end

            if response.status == 529 && retries < MAX_RETRIES
              retries += 1
              wait_time = ((2**retries) * 2) + rand(0.0..2.0)
              @logger.warn("Anthropic overloaded (529), retrying",
                           retry: retries, wait_seconds: wait_time.round(1))
              sleep(wait_time)
              next
            end

            raise ProviderError, "Anthropic returned #{response.status}: #{response.body}"
          end
        end

        def authenticated_client(api_key)
          HTTPX.with(
            headers: {
              "x-api-key" => api_key,
              "anthropic-version" => API_VERSION,
              "content-type" => "application/json"
            },
            timeout: { operation_timeout: @timeout }
          )
        end

        def raise_if_error!(response)
          raise_if_http_error!(response, "Anthropic", error_class: ProviderError)
        end

        def monotonic_ms
          Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
        end
      end
    end
  end
end
