# frozen_string_literal: true

require "semantic_logger"

module Homunculus
  module SAG
    # Adapts the Models::Router or legacy ModelProvider into the simple
    # callable interface that SAG components (GroundedGenerator, QueryAnalyzer)
    # expect: `adapter.call(prompt, max_tokens: 1024) → String`.
    #
    # Uses a fixed tier (:workhorse) to avoid keyword routing recursion —
    # the grounding prompt naturally contains the word "research" which would
    # otherwise trigger tier escalation.
    class LLMAdapter
      include SemanticLogger::Loggable

      # @param router [Models::Router, nil] Multi-model router (TUI with models.toml)
      # @param provider [ModelProvider, nil] Legacy single-provider (CLI/TUI fallback)
      # @param model [String, nil] Model name override for the legacy provider
      # @param default_model [String] Fallback model name when not derivable
      def initialize(router: nil, provider: nil, model: nil, default_model: "qwen2.5:14b")
        raise ArgumentError, "Either router: or provider: must be given" unless router || provider

        @router = router
        @provider = provider
        @model = model || default_model
      end

      # @param prompt [String] Text prompt to send to the LLM
      # @param max_tokens [Integer] Maximum response tokens
      # @return [String] The generated text content
      def call(prompt, max_tokens: 1024)
        messages = [
          { role: "system", content: "You are a research assistant. Answer concisely and accurately." },
          { role: "user", content: prompt }
        ]

        if @router
          call_via_router(messages, max_tokens)
        else
          call_via_provider(messages, max_tokens)
        end
      rescue Agent::Models::ProviderError => e
        logger.warn("SAG LLM adapter error (provider)", error: e.message)
        raise StandardError, "Research generation unavailable: #{e.message}"
      rescue StandardError => e
        logger.warn("SAG LLM adapter error", error: e.message)
        raise
      end

      private

      def call_via_router(messages, max_tokens)
        response = @router.generate(
          messages: messages,
          tools: nil,
          tier: :workhorse,
          user_message: "",
          stream: false
        )
        response.content.to_s
      end

      def call_via_provider(messages, max_tokens)
        response = @provider.complete(
          messages: messages,
          tools: nil,
          system: messages.first[:content],
          max_tokens: max_tokens,
          temperature: 0.3
        )
        response.content.to_s
      end
    end
  end
end
