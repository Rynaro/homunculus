# frozen_string_literal: true

module Homunculus
  module Agent
    # Background warm-up for Ollama models and workspace files.
    # Runs sequential preload steps in a thread so interfaces stay responsive.
    # Each step is independently rescued — one failure never blocks the rest.
    class Warmup
      include SemanticLogger::Loggable

      WORKSPACE_FILES = %w[SOUL.md AGENTS.md USER.md MEMORY.md].freeze
      STEPS = %i[preload_chat_model preload_embedding_model preread_workspace_files].freeze

      attr_reader :results

      def initialize(ollama_provider:, embedder:, config:, workspace_path:)
        @ollama_provider = ollama_provider
        @embedder = embedder
        @config = config
        @workspace_path = workspace_path

        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @done = false
        @results = {}
        @start_time = nil
        @end_time = nil
      end

      def start!(callback: nil)
        return skip_all!(callback) unless @config.agent.warmup.enabled

        @start_time = monotonic_now
        @thread = Thread.new { run_steps(callback) }
        @thread.abort_on_exception = false
        nil
      end

      def ready?
        @mutex.synchronize { @done }
      end

      def wait!
        @mutex.synchronize do
          @condition.wait(@mutex) until @done
        end
      end

      def elapsed_ms
        return nil unless @start_time

        end_time = @end_time || monotonic_now
        ((end_time - @start_time) * 1000).round
      end

      private

      def run_steps(callback)
        STEPS.each { |step| execute_step(step, callback) }

        @end_time = monotonic_now
        total = elapsed_ms
        logger.info("Warm-up complete", elapsed_ms: total, results: result_summary)
        callback&.call(:done, nil, { elapsed_ms: total, results: @results })

        mark_done!
      end

      def execute_step(step, callback)
        warmup_config = @config.agent.warmup

        if step_skipped?(step, warmup_config)
          record_result(step, :skipped)
          callback&.call(:skip, step, {})
          logger.debug("Warm-up step skipped", step: step)
          return
        end

        callback&.call(:start, step, {})
        step_start = monotonic_now

        send(step)

        step_elapsed = ((monotonic_now - step_start) * 1000).round
        record_result(step, :ok, elapsed_ms: step_elapsed)
        callback&.call(:complete, step, { elapsed_ms: step_elapsed })
        logger.info("Warm-up step complete", step: step, elapsed_ms: step_elapsed)
      rescue StandardError => e
        step_elapsed = ((monotonic_now - step_start) * 1000).round
        record_result(step, :failed, elapsed_ms: step_elapsed, error: e.message)
        callback&.call(:fail, step, { elapsed_ms: step_elapsed, error: e.message })
        logger.warn("Warm-up step failed", step: step, error: e.message, elapsed_ms: step_elapsed)
      end

      def step_skipped?(step, warmup_config)
        case step
        when :preload_chat_model
          @ollama_provider.nil? || !warmup_config.preload_chat_model
        when :preload_embedding_model
          @embedder.nil? || !warmup_config.preload_embedding_model
        when :preread_workspace_files
          !warmup_config.preread_workspace_files
        end
      end

      def preload_chat_model
        model_config = @config.models[:local]
        model_name = model_config&.default_model || model_config&.model
        raise "No local model configured" unless model_name

        @ollama_provider.preload_model(model_name)
      end

      def preload_embedding_model
        @embedder.embed("warmup")
      end

      def preread_workspace_files
        WORKSPACE_FILES.each do |filename|
          path = File.join(@workspace_path, filename)
          File.read(path) if File.exist?(path)
        end
      end

      def skip_all!(callback)
        @start_time = monotonic_now
        @end_time = @start_time
        STEPS.each { |step| record_result(step, :skipped) }
        callback&.call(:done, nil, { elapsed_ms: 0, results: @results })
        logger.info("Warm-up disabled, skipping all steps")
        mark_done!
        nil
      end

      def mark_done!
        @mutex.synchronize do
          @done = true
          @condition.broadcast
        end
      end

      def record_result(step, status, elapsed_ms: nil, error: nil)
        @results[step] = { status: status, elapsed_ms: elapsed_ms, error: error }.compact
      end

      def result_summary
        @results.transform_values { |r| r[:status] }
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
