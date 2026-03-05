# frozen_string_literal: true

require "semantic_logger"

module Homunculus
  module SAG
    QueryAnalysis = Data.define(:intent, :sub_queries, :original)

    class QueryAnalyzer
      include SemanticLogger::Loggable

      MAX_SUB_QUERIES = 4

      FACTUAL_PATTERNS = [
        /\bwhat is\b/i,
        /\bwho is\b/i,
        /\bwhen (was|did|is)\b/i,
        /\bwhere (is|was|are)\b/i,
        /\bdefine\b/i,
        /\bhow many\b/i
      ].freeze

      COMPARISON_PATTERNS = [
        /\bvs\.?\b/i,
        /\bversus\b/i,
        /\bcompare\b/i,
        /\bdifference between\b/i,
        /\bbetter than\b/i,
        /\bor\b.*\bwhich\b/i
      ].freeze

      def initialize(llm: nil)
        @llm = llm
      end

      def analyze(query)
        intent = detect_intent(query)
        sub_queries = decompose(query, intent)

        QueryAnalysis.new(
          intent: intent,
          sub_queries: sub_queries,
          original: query
        )
      end

      private

      def detect_intent(query)
        return :factual if FACTUAL_PATTERNS.any? { |p| query.match?(p) }
        return :comparison if COMPARISON_PATTERNS.any? { |p| query.match?(p) }

        :research
      end

      def decompose(query, intent)
        return [query] if intent == :factual
        return [query] if @llm.nil?

        llm_decompose(query)
      rescue StandardError => e
        logger.warn("Query decomposition failed, using original", error: e.message)
        [query]
      end

      def llm_decompose(query)
        prompt = <<~PROMPT
          Break the following research question into 1-4 focused search queries.
          Return one query per line, nothing else. No numbering, no bullets.
          If the question is already focused, return it as-is on one line.

          Question: #{query}
        PROMPT

        response = @llm.call(prompt, max_tokens: 256)
        queries = response.to_s.strip.split("\n").map(&:strip).reject(&:empty?)
        queries = queries.first(MAX_SUB_QUERIES)
        queries.empty? ? [query] : queries
      end
    end
  end
end
