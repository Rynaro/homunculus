# frozen_string_literal: true

module Homunculus
  module Agent
    module Models
      # ModelRouter — the brain of the multi-model routing system.
      # Resolves which provider and model tier to use for each request based on:
      #   1. Explicit tier override (from code or user command)
      #   2. Skill-based routing (skill_name → tier from config)
      #   3. Keyword signal detection (message content → tier)
      #   4. Default: workhorse
      #
      # Handles escalation from local to cloud on failures or low quality,
      # budget gating, and usage tracking.
      class Router
        include SemanticLogger::Loggable

        DEFAULT_TIER = :workhorse

        def initialize(config:, providers: {}, usage_tracker: nil)
          @config = config
          @providers = providers
          @tracker = usage_tracker
          @logger = SemanticLogger["ModelRouter"]
        end

        attr_reader :config, :providers, :tracker

        # Main entry point. Called by AgentLoop.
        #
        # @param messages [Array<Hash>] Conversation messages
        # @param tools [Array<Hash>, nil] Available tools
        # @param tier [Symbol, nil] Explicit tier override
        # @param skill_name [String, nil] Active skill name for routing lookup
        # @param user_message [String] Raw user message for keyword signal detection
        # @param stream [Boolean] Whether to stream the response
        # @yield [String] If stream: true, yields text chunks
        # @return [Models::Response]
        def generate(messages:, tools: nil, tier: nil, skill_name: nil, user_message: "", stream: false, &)
          resolved_tier = resolve_tier(tier:, skill_name:, user_message:)
          tier_config = @config.dig("tiers", resolved_tier.to_s)

          unless tier_config
            raise ConfigError, "Unknown tier: #{resolved_tier}. Available: #{@config.fetch("tiers", {}).keys.join(", ")}"
          end

          provider_name = tier_config.fetch("provider").to_sym
          provider = @providers.fetch(provider_name) do
            raise ConfigError, "Provider not registered: #{provider_name}. Available: #{@providers.keys.join(", ")}"
          end

          # Budget gate for cloud providers
          if provider_name == :anthropic && budget_exceeded?
            @logger.warn("Cloud budget exceeded, falling back to local thinker tier")
            return generate(messages:, tools:, tier: :thinker, stream:, &)
          end

          attempt_with_escalation(
            messages:, tools:, tier_config:, provider:,
            resolved_tier:, stream:, &
          )
        end

        # Resolve tier without making any LLM calls. Useful for logging/debugging.
        # @return [Symbol]
        def resolve_tier(tier: nil, skill_name: nil, user_message: "")
          return tier.to_sym if tier

          if skill_name
            mapped = @config.dig("routing", "skill_map", skill_name.to_s)
            return mapped.to_sym if mapped
          end

          detect_tier_from_keywords(user_message) || DEFAULT_TIER
        end

        private

        def detect_tier_from_keywords(message)
          keyword_map = @config.dig("routing", "keyword_signals") || {}
          return nil if message.nil? || message.empty?

          downcase_msg = message.downcase

          keyword_map.each do |keyword, tier_name|
            return tier_name.to_sym if downcase_msg.include?(keyword.to_s)
          end

          nil
        end

        def attempt_with_escalation(messages:, tools:, tier_config:, provider:, resolved_tier:, stream:, &)
          retries = 0
          max_retries = @config.dig("escalation", "max_local_retries") || 3

          loop do
            response = execute_request(
              provider:, tier_config:, messages:, tools:,
              resolved_tier:, stream:, &
            )

            # Quality check for local models
            if response.local? && low_quality?(response)
              @logger.warn("Low quality response detected", tier: resolved_tier, reason: quality_issue(response))
              return escalate_to_cloud(messages:, tools:, from_tier: resolved_tier, stream:, &) if escalation_enabled?
            end

            # Track usage
            @tracker&.record(response)

            return response
          rescue ProviderError => e
            retries += 1
            @logger.error("Provider error", attempt: retries, max: max_retries, error: e.message)

            if retries >= max_retries && escalation_enabled?
              @logger.warn("Max retries reached, escalating to cloud", from_tier: resolved_tier)
              return escalate_to_cloud(messages:, tools:, from_tier: resolved_tier, stream:, &)
            end

            raise if retries >= max_retries
          end
        end

        def execute_request(provider:, tier_config:, messages:, tools:, resolved_tier:, stream:, &block)
          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)

          model = tier_config.fetch("model")
          temperature = tier_config.fetch("temperature", 0.7)
          max_tokens = tier_config.fetch("max_tokens", 4096)
          context_window = tier_config.fetch("context_window", nil)

          raw_response = if stream && block
                           provider.generate_stream(
                             messages:, model:, tools:, temperature:,
                             max_tokens:, context_window:, &block
                           )
                         else
                           provider.generate(
                             messages:, model:, tools:, temperature:,
                             max_tokens:, context_window:
                           )
                         end

          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - start_time

          build_response(raw_response:, provider:, tier: resolved_tier, latency_ms: elapsed.round)
        end

        def escalate_to_cloud(messages:, tools:, from_tier:, stream:, &)
          cloud_tier = select_cloud_tier(from_tier)

          @logger.info("Escalating", from: from_tier, to: cloud_tier)

          tier_config = @config.dig("tiers", cloud_tier.to_s)
          raise ConfigError, "Cloud escalation tier not found: #{cloud_tier}" unless tier_config

          provider = @providers.fetch(:anthropic) do
            raise ConfigError, "Anthropic provider not registered for cloud escalation"
          end

          # Check budget before cloud escalation
          if budget_exceeded?
            @logger.warn("Cloud budget exceeded during escalation, falling back to local thinker")
            thinker_config = @config.dig("tiers", "thinker")
            if thinker_config && @providers[:ollama]
              return execute_request(
                provider: @providers[:ollama], tier_config: thinker_config,
                messages:, tools:, resolved_tier: :thinker, stream:, &
              )
            end
            raise ProviderError, "All escalation paths exhausted"
          end

          response = execute_request(
            provider:, tier_config:, messages:, tools:,
            resolved_tier: cloud_tier, stream:, &
          )

          # Return with escalation metadata
          escalated = Response.new(**response.to_h, escalated_from: from_tier)
          @tracker&.record(escalated)
          escalated
        end

        def select_cloud_tier(from_tier)
          case from_tier
          when :whisper, :workhorse then :cloud_fast
          when :coder                then :cloud_standard
          when :thinker              then :cloud_deep
          else                            :cloud_standard
          end
        end

        def low_quality?(response)
          return false unless @config.dig("escalation", "gibberish_detection")
          return false if response.finish_reason == :tool_use
          return true if response.content.nil? || response.content.strip.empty?
          return true if response.content.length < 10

          content = response.content
          detect_repetition(content) > 0.5
        end

        def quality_issue(response)
          return :empty if response.content.nil? || response.content.strip.empty?
          return :too_short if response.content.length < 10
          return :repetitive if detect_repetition(response.content) > 0.5

          :unknown
        end

        def detect_repetition(text)
          return 0.0 if text.nil? || text.length < 50

          words = text.split
          return 0.0 if words.length < 10

          unique_ratio = words.uniq.length.to_f / words.length
          1.0 - unique_ratio
        end

        def budget_exceeded?
          return false unless @tracker

          budget_limit = @config.dig("escalation", "cloud_budget_monthly_usd") || 30.0
          @tracker.monthly_cloud_spend_usd >= budget_limit
        end

        def escalation_enabled?
          @config.dig("defaults", "escalation_enabled") != false &&
            @providers.key?(:anthropic)
        end

        def build_response(raw_response:, provider:, tier:, latency_ms:)
          Response.new(
            content: raw_response[:content],
            tool_calls: raw_response[:tool_calls] || [],
            model: raw_response[:model],
            provider: provider.name.to_sym,
            tier: tier,
            usage: raw_response[:usage] || {},
            latency_ms: latency_ms,
            cost_usd: raw_response[:cost_usd] || 0.0,
            finish_reason: raw_response[:finish_reason] || :stop,
            escalated_from: nil,
            metadata: raw_response[:metadata] || {}
          )
        end
      end

      # Error classes for the models module
      class ConfigError < StandardError; end
      class ProviderError < StandardError; end
    end
  end
end
