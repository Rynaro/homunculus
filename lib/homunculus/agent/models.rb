# frozen_string_literal: true

require "json"
require "httpx"
require "digest"

# Multi-model routing module — tier-based LLM provider abstraction.
# Provides OllamaProvider (local) and AnthropicProvider (cloud escalation)
# with automatic routing, escalation, usage tracking, and health monitoring.
require_relative "../utils/argument_normalizer"
require_relative "../utils/http_error_handling"
require_relative "models/response"
require_relative "models/provider"
require_relative "models/ollama_provider"
require_relative "models/anthropic_provider"
require_relative "models/usage_tracker"
require_relative "models/health_monitor"
require_relative "models/router"

module Homunculus
  module Agent
    # Legacy ModelProvider — preserved for backward compatibility with existing
    # AgentLoop single-provider mode and specs. New code should use
    # Models::Router with Models::OllamaProvider / Models::AnthropicProvider.
    class ModelProvider
      include SemanticLogger::Loggable
      include Utils::ArgumentNormalizer
      include Utils::HttpErrorHandling

      Response = Data.define(:content, :tool_calls, :usage, :model, :stop_reason, :raw_response)
      ToolCall = Data.define(:id, :name, :arguments)
      TokenUsage = Data.define(:input_tokens, :output_tokens)

      OLLAMA_TIMEOUT = 120
      ANTHROPIC_TIMEOUT = 60
      ANTHROPIC_MAX_RETRIES = 3

      def initialize(config)
        @config = config
      end

      def complete(messages:, tools: nil, system: nil, max_tokens: 4096, temperature: nil)
        temp = temperature || @config.temperature
        model = @config.default_model || @config.model

        case @config.provider
        when "ollama"
          ollama_complete(messages, tools, system, max_tokens, temp, model)
        when "anthropic"
          anthropic_complete(messages, tools, system, max_tokens, temp, model)
        else
          raise ArgumentError, "Unknown provider: #{@config.provider}"
        end
      end

      private

      # ── Ollama ─────────────────────────────────────────────────────────

      def ollama_complete(messages, tools, system, max_tokens, temperature, model)
        url = "#{@config.base_url}/api/chat"

        payload = {
          model:,
          messages: format_ollama_messages(messages, system),
          stream: false,
          options: {
            temperature:,
            num_ctx: @config.context_window,
            num_predict: max_tokens
          }
        }

        payload[:tools] = tools.map { |t| format_ollama_tool(t) } if tools&.any?

        logger.debug("Ollama request", model:, message_count: messages.size, tools: tools&.size || 0)

        timeout = @config.respond_to?(:timeout_seconds) && @config.timeout_seconds ? @config.timeout_seconds : OLLAMA_TIMEOUT
        response = HTTPX
                   .with(timeout: { operation_timeout: timeout })
                   .post(url, json: payload)

        raise_if_error_response!(response, "Ollama")
        raise "Ollama request failed: #{response.status} — #{response.body}" unless response.status == 200

        parse_ollama_response(response, model)
      end

      def format_ollama_messages(messages, system)
        formatted = []
        formatted << { role: "system", content: system } if system

        messages.each do |msg|
          role = msg[:role].to_s
          case role
          when "tool"
            formatted << { role: "tool", content: msg[:content].to_s }
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
            formatted << entry
          else
            formatted << { role:, content: msg[:content].to_s }
          end
        end

        formatted
      end

      def format_ollama_tool(tool_def)
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

      def parse_ollama_response(http_response, model)
        parsed = JSON.parse(http_response.body.to_s)
        message = parsed["message"] || {}

        tool_calls = nil
        stop_reason = "end_turn"

        if message["tool_calls"]&.any?
          stop_reason = "tool_use"
          tool_calls = message["tool_calls"].map do |tc|
            func = tc["function"] || {}
            ToolCall.new(
              id: SecureRandom.uuid,
              name: func["name"],
              arguments: normalize_arguments(func["arguments"])
            )
          end
        end

        Response.new(
          content: message["content"],
          tool_calls:,
          usage: TokenUsage.new(
            input_tokens: parsed["prompt_eval_count"] || 0,
            output_tokens: parsed["eval_count"] || 0
          ),
          model:,
          stop_reason:,
          raw_response: parsed
        )
      end

      # ── Anthropic ──────────────────────────────────────────────────────

      def anthropic_complete(messages, tools, system, max_tokens, temperature, model)
        api_key = @config.api_key || ENV.fetch("ANTHROPIC_API_KEY", nil)
        raise SecurityError, "Anthropic API key not configured" unless api_key

        payload = {
          model:,
          max_tokens:,
          temperature:,
          messages: format_anthropic_messages(messages)
        }

        payload[:system] = system if system

        payload[:tools] = tools.map { |t| format_anthropic_tool(t) } if tools&.any?

        logger.debug("Anthropic request", model:, message_count: messages.size, tools: tools&.size || 0)

        response = anthropic_request_with_retry(payload, api_key)
        parse_anthropic_response(response, model)
      end

      def anthropic_request_with_retry(payload, api_key)
        retries = 0

        loop do
          response = HTTPX
                     .with(
                       headers: {
                         "x-api-key" => api_key,
                         "anthropic-version" => "2023-06-01",
                         "content-type" => "application/json"
                       },
                       timeout: { operation_timeout: ANTHROPIC_TIMEOUT }
                     )
                     .post("https://api.anthropic.com/v1/messages", json: payload)

          raise_if_error_response!(response, "Anthropic")
          return response if response.status == 200

          if response.status == 429 && retries < ANTHROPIC_MAX_RETRIES
            retries += 1
            wait_time = (2**retries) + rand(0.0..1.0)
            logger.warn("Anthropic rate limited (429), retrying in #{wait_time.round(1)}s",
                        retry: retries, max_retries: ANTHROPIC_MAX_RETRIES)
            sleep(wait_time)
            next
          end

          if response.status == 529 && retries < ANTHROPIC_MAX_RETRIES
            retries += 1
            wait_time = ((2**retries) * 2) + rand(0.0..2.0)
            logger.warn("Anthropic overloaded (529), retrying in #{wait_time.round(1)}s",
                        retry: retries, max_retries: ANTHROPIC_MAX_RETRIES)
            sleep(wait_time)
            next
          end

          raise "Anthropic request failed: #{response.status} — #{response.body}"
        end
      end

      def format_anthropic_messages(messages)
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
            content_blocks << { type: "text", text: msg[:content] } if msg[:content] && !msg[:content].empty?

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
          end
        end

        formatted
      end

      def format_anthropic_tool(tool_def)
        params = tool_def[:parameters] || {}
        {
          name: tool_def[:name],
          description: tool_def[:description],
          input_schema: params
        }
      end

      def parse_anthropic_response(http_response, model)
        parsed = JSON.parse(http_response.body.to_s)

        content_blocks = parsed["content"] || []
        text_content = content_blocks
                       .select { |b| b["type"] == "text" }
                       .map { |b| b["text"] }
                       .join

        tool_calls = nil
        tool_use_blocks = content_blocks.select { |b| b["type"] == "tool_use" }

        if tool_use_blocks.any?
          tool_calls = tool_use_blocks.map do |tc|
            ToolCall.new(
              id: tc["id"],
              name: tc["name"],
              arguments: normalize_arguments(tc["input"])
            )
          end
        end

        usage_data = parsed["usage"] || {}
        stop_reason = parsed["stop_reason"] == "tool_use" ? "tool_use" : parsed["stop_reason"] || "end_turn"

        Response.new(
          content: text_content.empty? ? nil : text_content,
          tool_calls:,
          usage: TokenUsage.new(
            input_tokens: usage_data["input_tokens"] || 0,
            output_tokens: usage_data["output_tokens"] || 0
          ),
          model:,
          stop_reason:,
          raw_response: parsed
        )
      end

      # ── Shared helpers ─────────────────────────────────────────────────

      def raise_if_error_response!(response, provider)
        raise_if_http_error!(response, provider)
      end
    end
  end
end
