# frozen_string_literal: true

require "semantic_logger"
require_relative "snippet"

module Homunculus
  module SAG
    class Reranker
      include SemanticLogger::Loggable

      def initialize(embedder: nil)
        @embedder = embedder
      end

      def rerank(query:, snippets:)
        return [] if snippets.empty?

        scored = if @embedder
                   rerank_with_embeddings(query, snippets)
                 else
                   positional_fallback(snippets)
                 end

        scored.sort_by { |s| -s.score }
      end

      private

      def rerank_with_embeddings(query, snippets)
        query_embedding = @embedder.embed(query)
        return positional_fallback(snippets) if query_embedding.nil?

        snippets.map do |snippet|
          snippet_embedding = @embedder.embed(snippet.text_for_embedding)
          if snippet_embedding
            score = Memory::Embedder.cosine_similarity(query_embedding, snippet_embedding)
            snippet.with_score(score)
          else
            snippet.with_score(0.0)
          end
        end
      rescue StandardError => e
        logger.warn("Embedding reranking failed, using positional fallback", error: e.message)
        positional_fallback(snippets)
      end

      def positional_fallback(snippets)
        count = snippets.size
        snippets.map.with_index do |snippet, index|
          score = 1.0 - (index.to_f / [count, 1].max)
          snippet.with_score(score)
        end
      end
    end
  end
end
