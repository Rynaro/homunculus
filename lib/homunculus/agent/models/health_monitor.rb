# frozen_string_literal: true

require "English"
module Homunculus
  module Agent
    module Models
      # Monitors the health of LLM providers and GPU resources.
      # Tracks which models are loaded in Ollama, provider availability,
      # and optionally VRAM usage via nvidia-smi.
      class HealthMonitor
        attr_reader :last_check_at

        def initialize(providers: {}, config: {})
          @providers = providers
          @config = config
          @logger = SemanticLogger["HealthMonitor"]
          @last_check_at = nil
          @cached_status = {}
        end

        # Run all health checks and cache the results.
        # @return [Hash] Full health status report
        def check_all
          @logger.debug("Running health checks")

          @cached_status = {
            ollama: check_ollama,
            anthropic: check_anthropic,
            gpu: gpu_status,
            checked_at: Time.now.iso8601
          }

          @last_check_at = Time.now
          @cached_status
        end

        # Is Ollama responding to health checks?
        # @return [Boolean]
        def ollama_healthy?
          ollama = @providers[:ollama]
          return false unless ollama

          ollama.available?
        rescue StandardError => e
          @logger.debug("Ollama health check failed", error: e.message)
          false
        end

        # List models currently available in Ollama.
        # @return [Array<String>]
        def ollama_loaded_models
          ollama = @providers[:ollama]
          return [] unless ollama

          ollama.list_models
        rescue StandardError => e
          @logger.debug("Failed to list Ollama models", error: e.message)
          []
        end

        # Can we reach the Anthropic API?
        # @return [Boolean]
        def anthropic_healthy?
          anthropic = @providers[:anthropic]
          return false unless anthropic

          anthropic.available?
        rescue StandardError
          false
        end

        # GPU status from nvidia-smi (if available).
        # @return [Hash] { vram_used_mb:, vram_total_mb:, temperature_c:, utilization_percent: }
        def gpu_status
          parse_nvidia_smi
        rescue StandardError => e
          @logger.debug("GPU status unavailable", error: e.message)
          { available: false, error: e.message }
        end

        # Full health report for the infra_sentinel skill.
        # @return [Hash]
        def status_report
          return @cached_status unless @cached_status.empty?

          check_all
        end

        # Whether enough time has passed for another health check.
        # @return [Boolean]
        def check_due?
          return true unless @last_check_at

          interval = @config.fetch("health_check_interval_seconds", 60)
          Time.now - @last_check_at >= interval
        end

        NVIDIA_SMI_CMD = "nvidia-smi --query-gpu=memory.used,memory.total," \
                         "temperature.gpu,utilization.gpu --format=csv,noheader,nounits 2>&1"
        private_constant :NVIDIA_SMI_CMD

        private

        def check_ollama
          ollama = @providers[:ollama]
          return { available: false, reason: "not configured" } unless ollama

          available = ollama.available?
          result = { available: available }

          if available
            models = ollama.list_models
            result[:loaded_models] = models
            result[:model_count] = models.size
          end

          result
        rescue StandardError => e
          { available: false, error: e.message }
        end

        def check_anthropic
          anthropic = @providers[:anthropic]
          return { available: false, reason: "not configured" } unless anthropic

          { available: anthropic.available? }
        rescue StandardError => e
          { available: false, error: e.message }
        end

        def parse_nvidia_smi
          output = `#{NVIDIA_SMI_CMD}`

          return { available: false, error: "nvidia-smi not available" } unless $CHILD_STATUS.success?

          parts = output.strip.split(",").map(&:strip)
          return { available: false, error: "unexpected nvidia-smi output" } if parts.size < 4

          {
            available: true,
            vram_used_mb: parts[0].to_i,
            vram_total_mb: parts[1].to_i,
            temperature_c: parts[2].to_i,
            utilization_percent: parts[3].to_i
          }
        end
      end
    end
  end
end
