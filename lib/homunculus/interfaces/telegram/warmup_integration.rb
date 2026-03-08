# frozen_string_literal: true

require_relative "../../agent/warmup"
require_relative "../../agent/models/ollama_provider"

module Homunculus
  module Interfaces
    class Telegram
      # Blocking warm-up for Telegram: preloads Ollama models before
      # @bot.listen so the first user message is fast. Log-only — no
      # user-facing messages are sent during warm-up.
      module WarmupIntegration
        def run_warmup!
          return unless @config.agent.warmup.enabled

          warmup = Agent::Warmup.new(
            ollama_provider: build_warmup_ollama_provider,
            embedder: @memory_store&.embedder,
            config: @config,
            workspace_path: @config.agent.workspace_path
          )
          warmup.start!(callback: method(:warmup_log))
          warmup.wait!
          logger.info("Telegram warm-up finished", elapsed_ms: warmup.elapsed_ms)
        rescue StandardError => e
          logger.warn("Warm-up failed, continuing startup", error: e.message)
        end

        private

        def build_warmup_ollama_provider
          local_config = @config.models[:local]
          return nil unless local_config

          ollama_config = {
            "base_url" => local_config.base_url,
            "timeout_seconds" => local_config.timeout_seconds || 120,
            "keep_alive" => "30m"
          }
          Agent::Models::OllamaProvider.new(config: ollama_config)
        rescue StandardError => e
          logger.warn("Could not create OllamaProvider for warmup", error: e.message)
          nil
        end

        def warmup_log(event, step, detail)
          case event
          when :start
            logger.info("Warmup: starting #{step}")
          when :complete
            logger.info("Warmup: #{step} complete", elapsed_ms: detail[:elapsed_ms])
          when :skip
            logger.debug("Warmup: #{step} skipped")
          when :fail
            logger.warn("Warmup: #{step} failed", error: detail[:error])
          when :done
            logger.info("Warmup complete", elapsed_ms: detail[:elapsed_ms])
          end
        end
      end
    end
  end
end
