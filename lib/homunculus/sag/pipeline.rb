# frozen_string_literal: true

require "semantic_logger"
require_relative "snippet"

module Homunculus
  module SAG
    PipelineResult = Data.define(:query, :analysis, :snippets, :response, :cited_urls, :confidence, :error) do
      def self.error(query, message)
        new(query: query, analysis: nil, snippets: [], response: nil, cited_urls: [], confidence: 0.0, error: message)
      end

      def success?
        error.nil?
      end

      def well_supported?
        success? && confidence >= 0.5 && !cited_urls.empty?
      end
    end

    class Pipeline
      include SemanticLogger::Loggable

      MAX_TOTAL_SNIPPETS = 10

      def initialize(analyzer:, retriever:, reranker:, generator:, processor:)
        @analyzer = analyzer
        @retriever = retriever
        @reranker = reranker
        @generator = generator
        @processor = processor
      end

      def run(query)
        analysis = @analyzer.analyze(query)

        all_snippets = retrieve_all(analysis.sub_queries)
        return PipelineResult.error(query, "No search results found") if all_snippets.empty?

        ranked = @reranker.rerank(query: query, snippets: all_snippets)

        generation = @generator.generate(query: query, snippets: ranked)
        return PipelineResult.error(query, generation.error) unless generation.success?

        processed = @processor.process(response: generation.response, snippets: ranked)

        PipelineResult.new(
          query: query,
          analysis: analysis,
          snippets: ranked,
          response: processed.text,
          cited_urls: processed.cited_snippets.map(&:url),
          confidence: processed.confidence,
          error: nil
        )
      rescue StandardError => e
        logger.error("SAG pipeline failed", query: query, error: e.message)
        PipelineResult.error(query, e.message)
      end

      private

      def retrieve_all(sub_queries)
        all = []
        seen_urls = Set.new

        sub_queries.each do |sq|
          results = @retriever.retrieve(query: sq)
          results.each do |snippet|
            next if seen_urls.include?(snippet.url)

            seen_urls.add(snippet.url)
            all << snippet
          end

          break if all.size >= MAX_TOTAL_SNIPPETS
        end

        reassign_ranks(all.first(MAX_TOTAL_SNIPPETS))
      end

      def reassign_ranks(snippets)
        snippets.each_with_index.map do |snippet, index|
          Snippet.new(
            url: snippet.url,
            title: snippet.title,
            body: snippet.body,
            score: snippet.score,
            source: snippet.source,
            rank: index + 1
          )
        end
      end
    end
  end
end
