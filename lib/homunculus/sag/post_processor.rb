# frozen_string_literal: true

module Homunculus
  module SAG
    ProcessedResult = Data.define(:text, :cited_snippets, :orphaned_citations, :confidence, :citation_count) do
      def well_cited?
        citation_count.positive? && orphaned_citations.empty?
      end

      def high_confidence?
        confidence >= 0.7
      end
    end

    class PostProcessor
      def process(response:, snippets:)
        return empty_result(response) if response.nil? || response.strip.empty?

        snippet_by_rank = snippets.to_h { |s| [s.rank, s] }
        cited_ranks = extract_citation_ranks(response)

        cited = []
        orphaned = []

        cited_ranks.each do |rank|
          if snippet_by_rank.key?(rank)
            cited << snippet_by_rank[rank]
          else
            orphaned << rank
          end
        end

        cited.uniq!(&:rank)
        confidence = compute_confidence(cited, snippets)

        ProcessedResult.new(
          text: response,
          cited_snippets: cited,
          orphaned_citations: orphaned,
          confidence: confidence,
          citation_count: cited.size
        )
      end

      private

      def extract_citation_ranks(text)
        text.scan(/\[(\d+)\]/).flatten.map(&:to_i)
      end

      def compute_confidence(cited, all_snippets)
        return 0.0 if all_snippets.empty?

        citation_ratio = cited.size.to_f / [all_snippets.size, 1].max
        avg_score = if cited.empty?
                      0.0
                    else
                      cited.sum(&:score) / cited.size
                    end

        (0.6 * citation_ratio) + (0.4 * avg_score)
      end

      def empty_result(response)
        ProcessedResult.new(
          text: response.to_s,
          cited_snippets: [],
          orphaned_citations: [],
          confidence: 0.0,
          citation_count: 0
        )
      end
    end
  end
end
