# frozen_string_literal: true

module Homunculus
  module SAG
    Snippet = Data.define(:url, :title, :body, :score, :source, :rank) do
      def self.from_search(url:, title:, body:, rank:)
        new(url: url, title: title, body: body, score: 0.0, source: :search, rank: rank)
      end

      def self.from_deep_fetch(url:, title:, body:, rank:)
        new(url: url, title: title, body: body, score: 0.0, source: :deep_fetch, rank: rank)
      end

      def with_score(new_score)
        self.class.new(url: url, title: title, body: body, score: new_score, source: source, rank: rank)
      end

      def text_for_embedding
        "#{title} #{body}"
      end

      def citation_label
        "[#{rank}]"
      end
    end
  end
end
