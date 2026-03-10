# frozen_string_literal: true

require_relative "../sag/snippet"
require_relative "../sag/search_backend/searxng"
require_relative "../sag/query_analyzer"
require_relative "../sag/retriever"
require_relative "../sag/reranker"
require_relative "../sag/grounded_generator"
require_relative "../sag/post_processor"
require_relative "../sag/pipeline"

module Homunculus
  module Tools
    class WebResearch < Base
      tool_name "web_research"
      description <<~DESC.strip
        PREFERRED tool for factual questions such as weather, news, prices, scores, and current events.
        Use BEFORE web_fetch when you need information but do not already have a specific URL.
        Research a topic by searching the web, synthesizing multiple sources, and returning a cited answer.
        Uses SearXNG for search, reranks results, and generates a grounded response with [N] citations.
        Returns the answer text, source URLs, and a confidence score.
      DESC
      trust_level :untrusted
      requires_confirmation false

      parameter :query, type: :string, description: "The research question or topic to investigate"
      parameter :deep_fetch, type: :string, description: "Fetch full page content for top results (true/false)",
                             required: false, enum: %w[true false]

      def initialize(pipeline_factory:)
        super()
        @pipeline_factory = pipeline_factory
      end

      def execute(arguments:, session:)
        query = arguments[:query]
        return Result.fail("Missing required parameter: query") unless query && !query.strip.empty?

        deep = arguments[:deep_fetch] == "true"
        pipeline = @pipeline_factory.call(deep_fetch: deep)
        result = pipeline.run(query)

        if result.success?
          output = format_output(result)
          Result.ok(output, confidence: result.confidence, cited_urls: result.cited_urls,
                            snippet_count: result.snippets.size)
        else
          Result.fail("Research failed: #{result.error}")
        end
      rescue StandardError => e
        Result.fail("Web research error: #{e.message}")
      end

      private

      def format_output(result)
        output = result.response.to_s

        if result.cited_urls.any?
          output += "\n\n---\nSources:\n"
          result.cited_urls.each_with_index do |url, i|
            output += "[#{i + 1}] #{url}\n"
          end
        end

        confidence_label = if result.confidence >= 0.7
                             "high"
                           elsif result.confidence >= 0.4
                             "medium"
                           else
                             "low"
                           end
        output += "\nConfidence: #{confidence_label} (#{(result.confidence * 100).round}%)"
        output
      end
    end
  end
end
