# frozen_string_literal: true

require "json"

module Homunculus
  module Agent
    # Lightweight agent worker that runs inside a Ractor.
    # Handles prompt building and LLM completion for a specific agent persona.
    #
    # Constraints for Ractor compatibility:
    # - No SemanticLogger (not Ractor-safe)
    # - No Dry::Struct (not shareable) — uses frozen hashes/Data objects
    # - Creates its own HTTPX client (no shared mutable state)
    # - All inputs/outputs must be shareable (frozen)
    class AgentWorker
      # @param definition [AgentDefinition] frozen agent definition
      # @param provider_configs [Hash] frozen hash of provider configurations
      def initialize(definition, provider_configs:)
        @definition = definition
        @provider_configs = provider_configs
        @providers = {}
        build_providers!
      end

      # Handle a single request. Returns a result hash.
      #
      # @param request [Hash] { id:, message:, session_context:, skill_context:, timestamp: }
      # @return [Hash] shareable result hash
      def handle(request)
        system_prompt = build_system_prompt(request)
        messages = build_messages(request)
        provider = select_provider

        response = provider.complete(
          messages:,
          tools: nil,
          system: system_prompt,
          max_tokens: 4096,
          temperature: 0.7
        )

        format_response(response)
      rescue StandardError => e
        { status: :error, content: nil, tool_calls: nil,
          error: "#{e.class}: #{e.message}", model: nil, usage: nil }
      end

      private

      def build_system_prompt(request)
        sections = []
        sections << "<agent_soul>\n#{@definition.soul}\n</agent_soul>"

        sections << "<agent_tools>\n#{@definition.tools_config}\n</agent_tools>" if @definition.tools_config

        sections << request[:skill_context] if request[:skill_context]

        ctx = request[:session_context]
        sections << "<conversation_context>\n#{ctx[:summary]}\n</conversation_context>" if ctx && ctx[:summary]

        sections.join("\n\n")
      end

      def build_messages(request)
        messages = []

        ctx = request[:session_context]
        messages.concat(ctx[:messages]) if ctx && ctx[:messages]

        messages << { role: "user", content: request[:message] }
        messages
      end

      def select_provider
        case @definition.model_preference
        when :escalation
          @providers[:escalation] || @providers[:local]
        else
          @providers[:local] || @providers[:escalation]
        end || @providers.values.first
      end

      def format_response(response)
        tool_calls = response.tool_calls&.map do |tc|
          { id: tc.id, name: tc.name, arguments: tc.arguments }
        end

        {
          status: response.stop_reason == "tool_use" ? :needs_tools : :completed,
          content: response.content,
          tool_calls: tool_calls,
          error: nil,
          model: response.model,
          usage: if response.usage
                   { input_tokens: response.usage.input_tokens,
                     output_tokens: response.usage.output_tokens }
                 end
        }
      end

      def build_providers!
        @provider_configs.each do |key, cfg|
          config_obj = ProviderConfigShim.new(cfg)
          @providers[key] = ModelProvider.new(config_obj)
        end
      end
    end

    # Minimal duck-type shim for ModelProvider config.
    # ModelProvider calls .provider, .base_url, .default_model, .model,
    # .context_window, .temperature, .api_key on its config.
    # This avoids passing Dry::Struct across Ractor boundaries.
    class ProviderConfigShim
      def initialize(hash)
        @data = hash
      end

      def provider       = @data[:provider]
      def base_url       = @data[:base_url]
      def default_model  = @data[:default_model]
      def model          = @data[:model]
      def context_window = @data[:context_window]
      def temperature    = @data[:temperature]
      def api_key        = @data[:api_key]
      def daily_budget_usd = @data[:daily_budget_usd]
    end
  end
end
