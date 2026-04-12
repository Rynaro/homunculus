# frozen_string_literal: true

require "json"
require "httpx"
require "securerandom"
require_relative "../../utils/argument_normalizer"
require_relative "../../utils/http_error_handling"

module Homunculus
  module Agent
    module Models
      # llama.cpp HTTP client for local model inference.
      # Communicates with llama-server's OpenAI-compatible REST API for chat completions,
      # health checks, and model introspection. The server loads the model at startup;
      # this provider is stateless with respect to model loading.
      #
      # Supports llama.cpp extended capabilities:
      #   - grammar:       GBNF grammar string for constrained generation
      #   - json_schema:   JSON Schema for structured output (response_format)
      #   - lora_adapters: Array of {path:, scale:} — informational; set at server startup
      #   - Custom samplers: temperature, top_k, top_p, min_p, repeat_penalty
      class LlamaCppProvider < Provider
        include Utils::ArgumentNormalizer
        include Utils::HttpErrorHandling

        DEFAULT_TIMEOUT = 120

        # Sampler parameters that may be passed through from tier-level llamacpp_options.
        SAMPLER_KEYS = %i[temperature top_k top_p min_p repeat_penalty].freeze

        def initialize(config:)
          super(name: :llamacpp, config: config)
          @base_url = config.fetch("base_url", "http://127.0.0.1:8080")
          @timeout  = config.fetch("timeout_seconds", DEFAULT_TIMEOUT)
          @llamacpp_options = config.fetch("llamacpp_options", {})
        end

        # Synchronous chat completion via POST /v1/chat/completions (OpenAI format).
        # Returns a normalized hash for the Router to wrap in a Response.
        def generate(messages:, model:, tools: nil, temperature: 0.7, max_tokens: 4096, context_window: nil, **options)
          payload = build_chat_payload(
            model:, messages:, tools:, temperature:, max_tokens:, stream: false,
            overrides: merged_options(options.merge(context_window: context_window))
          )

          @logger.debug("LlamaCpp request", model:, message_count: messages.size, tools: tools&.size || 0)
          start_time = monotonic_ms

          http_response = http_client.post("#{@base_url}/v1/chat/completions", json: payload)
          raise_if_error!(http_response)

          elapsed = monotonic_ms - start_time

          unless http_response.status == 200
            raise ProviderError,
                  "LlamaCpp returned #{http_response.status}: #{http_response.body}"
          end

          parsed = JSON.parse(http_response.body.to_s)
          result = parse_chat_response(parsed, model)

          @logger.info("LlamaCpp response",
                       model:, latency_ms: elapsed.round,
                       tokens_in: result[:usage][:prompt_tokens],
                       tokens_out: result[:usage][:completion_tokens],
                       finish_reason: result[:finish_reason])

          result
        end

        # Streaming chat completion via POST /v1/chat/completions with stream: true.
        # Uses SSE (Server-Sent Events) format: "data: {...}" lines, terminated by "data: [DONE]".
        # Yields each text chunk to the block as it arrives; returns aggregated result.
        def generate_stream(messages:, model:, tools: nil, temperature: 0.7, max_tokens: 4096,
                            context_window: nil, **options, &)
          payload = build_chat_payload(
            model:, messages:, tools:, temperature:, max_tokens:, stream: true,
            overrides: merged_options(options.merge(context_window: context_window))
          )

          @logger.debug("LlamaCpp stream request", model:, message_count: messages.size)

          aggregated_content = +""
          tool_calls         = []
          usage_data         = {}

          stream_client = HTTPX
                          .plugin(:stream)
                          .with(timeout: { read_timeout: Float::INFINITY, operation_timeout: @timeout })

          stream_response = stream_client.post("#{@base_url}/v1/chat/completions", json: payload, stream: true)

          raise_if_error!(stream_response)
          unless stream_response.status == 200
            body = begin
              stream_response.body.to_s
            rescue StandardError
              ""
            end
            raise ProviderError, "LlamaCpp returned #{stream_response.status}: #{body}"
          end

          begin
            stream_response.each_line do |line|
              process_sse_line(line.strip, aggregated_content, tool_calls, usage_data, &)
            end
          rescue HTTPX::Error => e
            raise ProviderError, "LlamaCpp stream error: #{e.message}"
          end

          build_stream_result(
            content: aggregated_content,
            tool_calls: tool_calls,
            model: model,
            usage_data: usage_data
          )
        end

        # Health check: GET /health returns 200 with {"status":"ok"} when llama-server is ready.
        def available?
          response = http_client.get("#{@base_url}/health")
          response.respond_to?(:status) && response.status == 200
        rescue StandardError => e
          @logger.debug("LlamaCpp health check failed", error: e.message)
          false
        end

        # Check if a model name appears in the server's loaded model list via GET /v1/models.
        # llama-server typically reports a single loaded model; returns true if any model
        # matches model_name, or if model_name is nil/empty and at least one model is loaded.
        def model_loaded?(model_name)
          response = http_client.get("#{@base_url}/v1/models")
          return false unless response.respond_to?(:status) && response.status == 200

          parsed = JSON.parse(response.body.to_s)
          models = (parsed["data"] || []).map { |m| m["id"].to_s }
          return models.any? if model_name.nil? || model_name.to_s.strip.empty?

          models.any? { |m| m == model_name.to_s || m.include?(model_name.to_s) }
        rescue StandardError => e
          @logger.debug("LlamaCpp model_loaded? check failed", model: model_name, error: e.message)
          false
        end

        # No-op: llama-server loads its model at process startup.
        # Implements the Provider interface contract; returns a sentinel hash.
        def preload_model(_model_name)
          @logger.debug("LlamaCpp preload_model called — model is loaded at server startup, nothing to do")
          { loaded: true, elapsed_ms: 0, note: "llama-server loads model at startup" }
        end

        private

        def http_client
          HTTPX.with(timeout: { operation_timeout: @timeout })
        end

        # Merge tier-level llamacpp_options with per-call options; per-call wins on conflict.
        def merged_options(call_options)
          symbolized_config = @llamacpp_options.transform_keys(&:to_sym)
          symbolized_config.merge(call_options.transform_keys(&:to_sym))
        end

        def build_chat_payload(model:, messages:, tools:, temperature:, max_tokens:, stream:, overrides: {})
          payload = {
            model: model,
            messages: format_messages(messages),
            stream: stream,
            temperature: temperature,
            max_tokens: max_tokens
          }

          payload[:max_context_length] = overrides[:context_window] if overrides[:context_window]

          apply_sampler_options!(payload, overrides)
          apply_grammar_options!(payload, overrides)

          payload[:tools] = tools.map { |t| format_tool(t) } if tools&.any?
          payload
        end

        # Merge custom sampler keys into the top-level payload (OpenAI-compat fields).
        def apply_sampler_options!(payload, extra)
          SAMPLER_KEYS.each do |key|
            payload[key] = extra[key] if extra.key?(key)
          end
        end

        # Apply llama.cpp grammar / structured-output extensions.
        def apply_grammar_options!(payload, extra)
          payload[:grammar] = extra[:grammar] if extra.key?(:grammar)

          if extra.key?(:json_schema)
            payload[:response_format] = {
              type: "json_schema",
              json_schema: extra[:json_schema]
            }
          end

          # lora_adapters are typically set at server startup; log if passed at call time.
          return unless extra.key?(:lora_adapters)

          @logger.warn("LlamaCpp lora_adapters passed at call time — ignored; set adapters at server startup")
        end

        def format_messages(messages)
          messages.map do |msg|
            role = msg[:role].to_s
            case role
            when "tool"
              { role: "tool", content: msg[:content].to_s, tool_call_id: msg[:tool_call_id] }
            when "assistant"
              entry = { role: "assistant", content: msg[:content].to_s }
              if msg[:tool_calls]
                entry[:tool_calls] = msg[:tool_calls].map do |tc|
                  {
                    id: tc.is_a?(Hash) ? tc[:id] : tc.id,
                    type: "function",
                    function: {
                      name: tc.is_a?(Hash) ? tc[:name] : tc.name,
                      arguments: serialize_arguments(tc.is_a?(Hash) ? tc[:arguments] : tc.arguments)
                    }
                  }
                end
              end
              entry
            else
              { role: role, content: msg[:content].to_s }
            end
          end
        end

        def format_tool(tool_def)
          params = tool_def[:parameters] || {}
          {
            type: "function",
            function: {
              name: tool_def[:name],
              description: tool_def[:description],
              parameters: params
            }
          }
        end

        # Parse a synchronous OpenAI-format response.
        def parse_chat_response(parsed, model)
          choice     = (parsed["choices"] || []).first || {}
          message    = choice["message"] || {}
          tool_calls = parse_tool_calls(message["tool_calls"])

          finish_reason = map_finish_reason(choice["finish_reason"], tool_calls)

          usage_data = parsed["usage"] || {}
          prompt_tokens     = usage_data["prompt_tokens"] || 0
          completion_tokens = usage_data["completion_tokens"] || 0

          {
            content: message["content"],
            tool_calls: tool_calls,
            model: model,
            usage: {
              prompt_tokens: prompt_tokens,
              completion_tokens: completion_tokens,
              total_tokens: prompt_tokens + completion_tokens
            },
            finish_reason: finish_reason,
            cost_usd: 0.0,
            metadata: { id: parsed["id"] }
          }
        end

        # Process a single SSE line from the streaming response.
        def process_sse_line(line, aggregated_content, tool_calls, usage_data, &block)
          return if line.empty? || !line.start_with?("data: ")

          data = line.delete_prefix("data: ")
          return if data == "[DONE]"

          chunk = JSON.parse(data)
          choice  = (chunk["choices"] || []).first || {}
          delta   = choice["delta"] || {}

          if delta["content"] && !delta["content"].empty?
            aggregated_content << delta["content"]
            block&.call(delta["content"])
          end

          tool_calls.concat(parse_tool_calls(delta["tool_calls"])) if delta["tool_calls"]&.any?

          usage_data.merge!(chunk["usage"]) if chunk["usage"]
        rescue JSON::ParserError
          # Malformed chunk — skip silently
        end

        def build_stream_result(content:, tool_calls:, model:, usage_data:)
          prompt_tokens     = usage_data["prompt_tokens"] || 0
          completion_tokens = usage_data["completion_tokens"] || 0

          {
            content: content.empty? ? nil : content,
            tool_calls: tool_calls,
            model: model,
            usage: {
              prompt_tokens: prompt_tokens,
              completion_tokens: completion_tokens,
              total_tokens: prompt_tokens + completion_tokens
            },
            finish_reason: tool_calls.any? ? :tool_use : :stop,
            cost_usd: 0.0,
            metadata: {}
          }
        end

        # Map OpenAI finish_reason strings to normalized symbols.
        def map_finish_reason(raw, tool_calls)
          return :tool_use if tool_calls.any?

          case raw
          when "stop"       then :stop
          when "length"     then :length
          when "tool_calls" then :tool_use
          else                   :stop
          end
        end

        # Parse OpenAI-format tool_calls array from a message or delta.
        def parse_tool_calls(raw_tool_calls)
          return [] unless raw_tool_calls&.any?

          raw_tool_calls.map do |tc|
            func = tc["function"] || {}
            {
              id: tc["id"] || SecureRandom.uuid,
              name: func["name"],
              arguments: normalize_arguments(func["arguments"])
            }
          end
        end

        # Serialize tool-call arguments back to a JSON string (OpenAI format expects string).
        def serialize_arguments(args)
          case args
          when String then args
          when Hash   then JSON.generate(args)
          else             "{}"
          end
        end

        def raise_if_error!(response)
          raise_if_http_error!(response, "LlamaCpp", error_class: ProviderError)
        end

        def monotonic_ms
          Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
        end
      end
    end
  end
end
