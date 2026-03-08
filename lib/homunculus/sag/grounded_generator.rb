# frozen_string_literal: true

require "semantic_logger"

module Homunculus
  module SAG
    GenerationResult = Data.define(:query, :response, :snippets_used, :prompt_chars, :error) do
      def success?
        error.nil?
      end
    end

    class GroundedGenerator
      include SemanticLogger::Loggable

      MAX_SNIPPETS_IN_PROMPT = 6
      MAX_SNIPPET_CHARS = 800

      def initialize(llm:, max_tokens: 1024)
        @llm = llm
        @max_tokens = max_tokens
      end

      def generate(query:, snippets:)
        selected = snippets.first(MAX_SNIPPETS_IN_PROMPT)
        prompt = build_grounding_prompt(query, selected)

        response = @llm.call(prompt, max_tokens: @max_tokens)

        GenerationResult.new(
          query: query,
          response: response,
          snippets_used: selected.size,
          prompt_chars: prompt.length,
          error: nil
        )
      rescue StandardError => e
        logger.warn("Grounded generation failed", error: e.message)
        GenerationResult.new(
          query: query,
          response: nil,
          snippets_used: 0,
          prompt_chars: 0,
          error: e.message
        )
      end

      private

      def build_grounding_prompt(query, snippets)
        sources = snippets.map do |s|
          body = s.body.to_s
          body = body[0...MAX_SNIPPET_CHARS] if body.length > MAX_SNIPPET_CHARS
          "[#{s.rank}] #{s.title}\nURL: #{s.url}\n#{body}"
        end.join("\n\n")

        <<~PROMPT
          You are a research assistant. Answer the user's question using ONLY the provided sources.
          Cite sources using [N] notation inline. Do not use information outside the sources.
          If the sources don't contain enough information, say so honestly.

          Example:
          Question: What is Ruby?
          Sources:
          [1] Ruby Programming Language
          URL: https://ruby-lang.org
          Ruby is a dynamic, open source programming language with a focus on simplicity and productivity.

          Answer: Ruby is a dynamic, open source programming language focused on simplicity and productivity [1].

          ---

          Question: #{query}

          Sources:
          #{sources}

          Answer:
        PROMPT
      end
    end
  end
end
