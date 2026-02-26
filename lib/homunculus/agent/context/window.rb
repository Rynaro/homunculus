# frozen_string_literal: true

module Homunculus
  module Agent
    module Context
      class Window
        include SemanticLogger::Loggable

        # @param budget [Budget] context budget allocator
        # @param compressor [Compressor, nil] optional conversation compressor
        def initialize(budget:, compressor: nil)
          @budget = budget
          @compressor = compressor
        end

        # Apply sliding window to messages to fit within conversation budget.
        # Keeps recent messages and summarizes/drops older ones.
        #
        # @param messages [Array<Hash>] full message history
        # @return [Array<Hash>] windowed messages fitting budget
        def apply(messages)
          return messages if messages.nil? || messages.empty?

          max_tokens = @budget.tokens_for(:conversation)
          return messages if total_tokens(messages) <= max_tokens

          # Walk backwards keeping recent messages until budget is exhausted
          recent = []
          used_tokens = 0

          messages.reverse_each do |msg|
            msg_tokens = message_tokens(msg)
            break if used_tokens + msg_tokens > max_tokens * 0.8 # Reserve 20% for summary

            recent.unshift(msg)
            used_tokens += msg_tokens
          end

          # If we kept everything, no windowing needed
          return messages if recent.length == messages.length

          older = messages.first(messages.length - recent.length)
          summary_budget = (max_tokens * 0.2).floor

          summary_msg = build_summary(older, summary_budget)
          summary_msg ? [summary_msg, *recent] : recent
        end

        private

        def total_tokens(messages)
          messages.sum { |msg| message_tokens(msg) }
        end

        def message_tokens(msg)
          content = msg[:content] || msg["content"]
          TokenCounter.estimate(content.to_s)
        end

        def build_summary(older_messages, budget_tokens)
          return nil if older_messages.empty?

          summary_text = if @compressor
                           @compressor.summarize(older_messages, max_tokens: budget_tokens)
                         else
                           simple_truncation(older_messages, budget_tokens)
                         end

          return nil if summary_text.nil? || summary_text.strip.empty?

          logger.info("Conversation windowed", older_messages: older_messages.length,
                                               summary_tokens: TokenCounter.estimate(summary_text))

          { role: "system", content: "[Conversation summary] #{summary_text}" }
        end

        def simple_truncation(messages, budget_tokens)
          lines = messages.filter_map do |msg|
            role = msg[:role] || msg["role"]
            content = (msg[:content] || msg["content"]).to_s
            first_line = content.lines.first&.strip
            "#{role}: #{first_line}" if first_line && !first_line.empty?
          end

          result = lines.join("\n")
          TokenCounter.truncate_to_tokens(result, budget_tokens)
        end
      end
    end
  end
end
