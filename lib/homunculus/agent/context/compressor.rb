# frozen_string_literal: true

module Homunculus
  module Agent
    module Context
      class Compressor
        include SemanticLogger::Loggable

        SUMMARIZE_PROMPT = "Summarize the following conversation concisely, preserving key decisions, " \
                           "facts, and action items. Respond with only the summary, no preamble."

        # @param models_router [Homunculus::Agent::Models::Router, nil]
        def initialize(models_router: nil)
          @models_router = models_router
        end

        # Summarize a list of messages into a concise text.
        # Falls back to deterministic extraction if LLM fails.
        #
        # @param messages [Array<Hash>] conversation messages
        # @param max_tokens [Integer] target output token count
        # @return [String] summary text
        def summarize(messages, max_tokens:)
          return "" if messages.nil? || messages.empty?

          text = format_messages(messages)
          return deterministic_fallback(messages, max_tokens) unless @models_router

          llm_summarize(text, max_tokens)
        rescue StandardError => e
          logger.warn("LLM summarization failed, using deterministic fallback", error: e.message)
          deterministic_fallback(messages, max_tokens)
        end

        private

        def llm_summarize(text, max_tokens)
          prompt_messages = [
            { role: "system", content: SUMMARIZE_PROMPT },
            { role: "user", content: text }
          ]

          response = @models_router.generate(
            messages: prompt_messages,
            tools: nil,
            tier: :whisper,
            user_message: text
          )

          summary = response.content.to_s.strip
          return deterministic_fallback_from_text(text, max_tokens) if summary.empty?

          TokenCounter.truncate_to_tokens(summary, max_tokens)
        end

        def format_messages(messages)
          messages.map do |msg|
            role = msg[:role] || msg["role"]
            content = msg[:content] || msg["content"]
            "#{role}: #{content}"
          end.join("\n")
        end

        # Extract first line of each user message as a minimal summary.
        def deterministic_fallback(messages, max_tokens)
          lines = messages.filter_map do |msg|
            role = msg[:role] || msg["role"]
            content = (msg[:content] || msg["content"]).to_s
            next unless role.to_s == "user"

            first_line = content.lines.first&.strip
            "- #{first_line}" if first_line && !first_line.empty?
          end

          result = lines.join("\n")
          TokenCounter.truncate_to_tokens(result, max_tokens)
        end

        def deterministic_fallback_from_text(text, max_tokens)
          lines = text.lines.filter_map do |line|
            stripped = line.strip
            next if stripped.empty?

            first_sentence = stripped.split(/[.!?]/).first&.strip
            "- #{first_sentence}" if first_sentence && !first_sentence.empty?
          end

          result = lines.first(10).join("\n")
          TokenCounter.truncate_to_tokens(result, max_tokens)
        end
      end
    end
  end
end
