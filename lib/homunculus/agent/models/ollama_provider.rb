# frozen_string_literal: true

require "json"
require "httpx"
require "securerandom"
require_relative "../../utils/argument_normalizer"
require_relative "../../utils/http_error_handling"

module Homunculus
  module Agent
    module Models
      # Ollama HTTP client for local model inference.
      # Communicates with Ollama's REST API for chat completions,
      # model management, and health checks.
      class OllamaProvider < Provider
        include Utils::ArgumentNormalizer
        include Utils::HttpErrorHandling

        DEFAULT_TIMEOUT = 120

        def initialize(config:)
          super(name: :ollama, config: config)
          @base_url = config.fetch("base_url", "http://127.0.0.1:11434")
          @keep_alive = config.fetch("keep_alive", "30m")
          @timeout = config.fetch("timeout_seconds", DEFAULT_TIMEOUT)
        end

        # Synchronous chat completion via POST /api/chat.
        # Returns a normalized hash for the Router to wrap in a Response.
        def generate(messages:, model:, tools: nil, temperature: 0.7, max_tokens: 4096, context_window: nil)
          payload = build_chat_payload(
            model:, messages:, tools:,
            temperature:, max_tokens:, stream: false, context_window:
          )

          @logger.debug("Ollama request", model:, message_count: messages.size, tools: tools&.size || 0)
          start_time = monotonic_ms

          http_response = http_client.post("#{@base_url}/api/chat", json: payload)
          raise_if_error!(http_response)

          elapsed = monotonic_ms - start_time

          raise ProviderError, "Ollama returned #{http_response.status}: #{http_response.body}" unless http_response.status == 200

          parsed = JSON.parse(http_response.body.to_s)
          result = parse_chat_response(parsed, model)

          @logger.info("Ollama response",
                       model:, latency_ms: elapsed.round,
                       tokens_in: result[:usage][:prompt_tokens],
                       tokens_out: result[:usage][:completion_tokens],
                       finish_reason: result[:finish_reason])

          result
        end

        # Streaming chat completion. Uses HTTP streaming so the connection stays alive and
        # chunks are processed as they arrive (avoids single long operation timeout).
        # Parses Ollama's NDJSON format line by line; yields each text chunk to the block.
        def generate_stream(messages:, model:, tools: nil, temperature: 0.7, max_tokens: 4096, context_window: nil, &block)
          payload = build_chat_payload(
            model:, messages:, tools:,
            temperature:, max_tokens:, stream: true, context_window:
          )

          @logger.debug("Ollama stream request", model:, message_count: messages.size)

          aggregated_content = +""
          tool_calls = []
          final_data = {}

          # Use stream plugin so we read line-by-line as data arrives; override plugin's 60s default
          stream_client = HTTPX
                          .plugin(:stream)
                          .with(timeout: { read_timeout: Float::INFINITY, operation_timeout: @timeout })

          stream_response = stream_client.post("#{@base_url}/api/chat", json: payload, stream: true)

          begin
            stream_response.each_line do |line|
              line = line.strip
              next if line.empty?

              chunk = JSON.parse(line)
              message = chunk["message"] || {}

              if message["content"] && !message["content"].empty?
                aggregated_content << message["content"]
                block&.call(message["content"])
              end

              tool_calls.concat(parse_tool_calls(message["tool_calls"])) if message["tool_calls"]&.any?

              final_data = chunk if chunk["done"]
            end
          rescue HTTPX::Error => e
            raise ProviderError, "Ollama stream error: #{e.message}"
          end

          # StreamResponse#each already calls response.raise_for_status, so reaching here means success

          build_result(
            content: aggregated_content,
            tool_calls: tool_calls,
            model: model,
            final_data: final_data
          )
        end

        # Health check: GET /api/tags returns 200 if Ollama is running.
        def available?
          response = http_client.get("#{@base_url}/api/tags")
          response.respond_to?(:status) && response.status == 200
        rescue StandardError => e
          @logger.debug("Ollama health check failed", error: e.message)
          false
        end

        # Check if a specific model is loaded via POST /api/show.
        def model_loaded?(model)
          response = http_client.post("#{@base_url}/api/show", json: { name: model })
          response.respond_to?(:status) && response.status == 200
        rescue StandardError => e
          @logger.debug("Model loaded check failed", model:, error: e.message)
          false
        end

        # List all available models via GET /api/tags.
        def list_models
          response = http_client.get("#{@base_url}/api/tags")
          raise_if_error!(response)
          return [] unless response.status == 200

          parsed = JSON.parse(response.body.to_s)
          (parsed["models"] || []).map { |m| m["name"] }
        rescue StandardError => e
          @logger.warn("Failed to list Ollama models", error: e.message)
          []
        end

        private

        def http_client
          HTTPX.with(timeout: { operation_timeout: @timeout })
        end

        def build_chat_payload(model:, messages:, tools:, temperature:, max_tokens:, stream:, context_window: nil)
          options = {
            temperature: temperature,
            num_predict: max_tokens
          }
          options[:num_ctx] = context_window if context_window

          payload = {
            model: model,
            messages: format_messages(messages),
            stream: stream,
            options: options,
            keep_alive: @keep_alive
          }

          payload[:tools] = tools.map { |t| format_tool(t) } if tools&.any?
          payload
        end

        def format_messages(messages)
          messages.map do |msg|
            role = msg[:role].to_s
            case role
            when "tool"
              { role: "tool", content: msg[:content].to_s }
            when "assistant"
              entry = { role: "assistant", content: msg[:content].to_s }
              if msg[:tool_calls]
                entry[:tool_calls] = msg[:tool_calls].map do |tc|
                  {
                    function: {
                      name: tc.is_a?(Hash) ? tc[:name] : tc.name,
                      arguments: tc.is_a?(Hash) ? tc[:arguments] : tc.arguments
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

        def parse_chat_response(parsed, model)
          message = parsed["message"] || {}
          tool_calls = parse_tool_calls(message["tool_calls"])
          finish_reason = tool_calls.any? ? :tool_use : :stop

          {
            content: message["content"],
            tool_calls: tool_calls,
            model: model,
            usage: {
              prompt_tokens: parsed["prompt_eval_count"] || 0,
              completion_tokens: parsed["eval_count"] || 0,
              total_tokens: (parsed["prompt_eval_count"] || 0) + (parsed["eval_count"] || 0)
            },
            finish_reason: finish_reason,
            cost_usd: 0.0,
            metadata: {
              total_duration: parsed["total_duration"],
              load_duration: parsed["load_duration"]
            }
          }
        end

        def parse_tool_calls(raw_tool_calls)
          return [] unless raw_tool_calls&.any?

          raw_tool_calls.map do |tc|
            func = tc["function"] || {}
            {
              id: SecureRandom.uuid,
              name: func["name"],
              arguments: normalize_arguments(func["arguments"])
            }
          end
        end

        def build_result(content:, tool_calls:, model:, final_data:)
          finish_reason = tool_calls.any? ? :tool_use : :stop

          {
            content: content.empty? ? nil : content,
            tool_calls: tool_calls,
            model: model,
            usage: {
              prompt_tokens: final_data["prompt_eval_count"] || 0,
              completion_tokens: final_data["eval_count"] || 0,
              total_tokens: (final_data["prompt_eval_count"] || 0) + (final_data["eval_count"] || 0)
            },
            finish_reason: finish_reason,
            cost_usd: 0.0,
            metadata: {
              total_duration: final_data["total_duration"],
              load_duration: final_data["load_duration"]
            }
          }
        end

        def raise_if_error!(response)
          raise_if_http_error!(response, "Ollama", error_class: ProviderError)
        end

        def monotonic_ms
          Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
        end
      end
    end
  end
end
