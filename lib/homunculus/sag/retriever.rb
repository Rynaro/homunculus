# frozen_string_literal: true

require "httpx"
require "nokogiri"
require "semantic_logger"
require_relative "../tools/base"
require_relative "../tools/web"
require_relative "snippet"

module Homunculus
  module SAG
    class Retriever
      include SemanticLogger::Loggable

      MAX_DEEP_FETCH_COUNT = 3
      MAX_DEEP_FETCH_CHARS = 3000
      DEEP_FETCH_TIMEOUT = 10

      def initialize(backend:, deep_fetch: false, top_n: 5)
        @backend = backend
        @deep_fetch = deep_fetch
        @top_n = top_n
      end

      def retrieve(query:)
        snippets = @backend.search(query: query, limit: @top_n)
        return snippets unless @deep_fetch

        deep_fetch_snippets(snippets)
      end

      private

      def deep_fetch_snippets(snippets)
        enriched = snippets.dup
        targets = snippets.first(MAX_DEEP_FETCH_COUNT)

        targets.each do |snippet|
          fetched = fetch_full_page(snippet)
          next unless fetched

          index = enriched.index { |s| s.url == snippet.url }
          enriched[index] = fetched if index
        end

        enriched
      end

      def fetch_full_page(snippet)
        response = HTTPX
                   .with(timeout: { operation_timeout: DEEP_FETCH_TIMEOUT })
                   .plugin(:follow_redirects, max_redirects: 3)
                   .with(headers: { "User-Agent" => Tools::WebFetch::DEFAULT_USER_AGENT })
                   .get(snippet.url)

        return nil unless response.respond_to?(:status) && response.status == 200

        html = response.body.to_s
        text = extract_text(html)
        text = text[0...MAX_DEEP_FETCH_CHARS] if text.length > MAX_DEEP_FETCH_CHARS

        Snippet.from_deep_fetch(
          url: snippet.url,
          title: snippet.title,
          body: text,
          rank: snippet.rank
        )
      rescue StandardError => e
        logger.warn("Deep fetch failed", url: snippet.url, error: e.message)
        nil
      end

      def extract_text(html)
        doc = Nokogiri::HTML(html)
        doc.css("script, style, noscript, iframe, object, embed, svg, nav, footer, header").remove

        text = doc.css("body").text
        text = doc.text if text.strip.empty?

        text
          .gsub(/[ \t]+/, " ")
          .gsub(/\n{3,}/, "\n\n")
          .strip
      end
    end
  end
end
