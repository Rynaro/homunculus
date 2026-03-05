# frozen_string_literal: true

require "httpx"
require "oj"
require "semantic_logger"
require_relative "../snippet"
require_relative "base"

module Homunculus
  module SAG
    module SearchBackend
      class SearXNG < Base
        include SemanticLogger::Loggable

        def initialize(base_url:, categories: ["general"], timeout: 15)
          super()
          @base_url = base_url.chomp("/")
          @categories = categories
          @timeout = timeout
        end

        def search(query:, limit: 5)
          params = {
            q: query,
            format: "json",
            categories: @categories.join(","),
            language: "en"
          }

          response = HTTPX
                     .with(timeout: { operation_timeout: @timeout })
                     .get("#{@base_url}/search", params: params)

          unless response.respond_to?(:status)
            msg = response.respond_to?(:error) && response.error ? response.error.message : "unknown"
            logger.warn("SearXNG search failed (connection error)", error: msg)
            return []
          end

          unless response.status == 200
            logger.warn("SearXNG search failed", status: response.status)
            return []
          end

          parse_results(response.body.to_s, limit)
        rescue StandardError => e
          logger.warn("SearXNG search error", error: e.message)
          []
        end

        def available?
          response = HTTPX
                     .with(timeout: { operation_timeout: 5 })
                     .get("#{@base_url}/healthz")

          response.respond_to?(:status) && response.status == 200
        rescue StandardError
          false
        end

        private

        def parse_results(body, limit)
          data = Oj.load(body)
          results = data["results"]
          return [] unless results.is_a?(Array)

          results.first(limit).each_with_index.map do |result, index|
            Snippet.from_search(
              url: result["url"].to_s,
              title: result["title"].to_s,
              body: (result["content"] || result["description"]).to_s,
              rank: index + 1
            )
          end
        rescue StandardError => e
          logger.warn("SearXNG JSON parse error", error: e.message)
          []
        end
      end
    end
  end
end
