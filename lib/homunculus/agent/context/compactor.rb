# frozen_string_literal: true

module Homunculus
  module Agent
    module Context
      class Compactor
        include SemanticLogger::Loggable

        FLUSH_MARKER = "[SYSTEM — CONTEXT MAINTENANCE]"
        FLUSH_INSTRUCTION = <<~MSG.strip
          #{FLUSH_MARKER}
          Your conversation context is approaching its limit. Before older messages are compacted, \
          save any important facts, decisions, or action items to long-term memory using the \
          memory_save or memory_daily_log tools. You have one turn to do this. \
          If there is nothing worth saving, respond briefly and we will proceed.
        MSG

        # @param config [Homunculus::ContextConfig] context configuration
        # @param budget [Homunculus::Agent::Context::Budget] token budget
        # @param compressor [Homunculus::Agent::Context::Compressor] message compressor
        def initialize(config:, budget:, compressor:)
          @config = config
          @budget = budget
          @compressor = compressor
          @flush_in_progress = false
        end

        # Returns true when conversation tokens >= soft_threshold * conversation_budget.
        # Returns false if compaction is disabled or a flush is already in progress.
        def needs_compaction?(messages)
          return false unless @config.compaction_enabled
          return false if @flush_in_progress

          conversation_budget = @budget.tokens_for(:conversation)
          current_tokens = estimate_tokens(messages)
          threshold = (conversation_budget * @config.compaction_soft_threshold).floor

          current_tokens >= threshold
        end

        # Returns a user-role message instructing the agent to flush facts to memory.
        # Sets flush_in_progress flag to prevent re-entrant compaction.
        def flush_message
          @flush_in_progress = true
          { role: :user, content: FLUSH_INSTRUCTION }
        end

        # Compacts older messages, preserving the most recent turns.
        # Summarizes older messages via the Compressor (whisper tier).
        # Strips flush artifacts from the result.
        #
        # @param messages [Array<Hash>] full message history (API format)
        # @return [Array<Hash>] compacted message array
        def compact(messages)
          split = find_split_index(messages)
          older = messages.first(split)
          recent = messages.slice(split..)

          recent = strip_flush_artifacts(recent)

          if older.empty?
            reset!
            return recent
          end

          summary_budget = @config.compaction_reserve_floor
          summary_text = @compressor.summarize(older, max_tokens: summary_budget)

          result = if summary_text && !summary_text.strip.empty?
                     summary_msg = { role: "system", content: "[Compacted context] #{summary_text}" }
                     [summary_msg, *recent]
                   else
                     recent
                   end

          logger.info("Context compacted",
                      older_messages: older.length,
                      recent_messages: recent.length,
                      summary_tokens: TokenCounter.estimate(summary_text.to_s))

          reset!
          result
        end

        # Clears all internal state flags.
        def reset!
          @flush_in_progress = false
        end

        # Visible for testing
        def flush_in_progress?
          @flush_in_progress
        end

        private

        # Find the split point: keep the last N assistant messages (and their surrounding context).
        # Returns the index where "older" messages end.
        def find_split_index(messages)
          preserved = @config.compaction_preserved_turns
          assistant_indices = messages.each_index.select { |i| messages[i][:role]&.to_s == "assistant" }

          return 0 if assistant_indices.length <= preserved

          # Split just before the Nth-from-last assistant message
          assistant_indices[-preserved]
        end

        def strip_flush_artifacts(messages)
          messages.reject do |msg|
            content = (msg[:content] || msg["content"]).to_s
            content.include?(FLUSH_MARKER)
          end
        end

        def estimate_tokens(messages)
          messages.sum do |msg|
            content = msg[:content] || msg["content"]
            TokenCounter.estimate(content.to_s)
          end
        end
      end
    end
  end
end
