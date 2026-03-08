# frozen_string_literal: true

require "semantic_logger"
require_relative "query_analyzer"
require_relative "retriever"
require_relative "reranker"
require_relative "grounded_generator"
require_relative "post_processor"
require_relative "search_backend/searxng"
require_relative "pipeline"

module Homunculus
  module SAG
    # Constructs fully-wired SAG::Pipeline instances from config and an LLM adapter.
    # Passed as the `pipeline_factory:` to Tools::WebResearch.
    #
    #   factory = PipelineFactory.new(config: config.sag, llm_adapter: adapter)
    #   pipeline = factory.call(deep_fetch: true)
    #   result = pipeline.run("What is Ruby?")
    class PipelineFactory
      include SemanticLogger::Loggable

      # @param config [SAGConfig] The sag section of the application config
      # @param llm_adapter [LLMAdapter] Callable adapter for LLM generation
      # @param embedder [Memory::Embedder, nil] Optional embedder for semantic reranking
      def initialize(config:, llm_adapter:, embedder: nil)
        @config = config
        @llm_adapter = llm_adapter
        @embedder = embedder
      end

      # @param deep_fetch [Boolean] Whether to fetch full page content for top results
      # @return [SAG::Pipeline] A ready-to-run pipeline instance
      def call(deep_fetch: false)
        backend = SearchBackend::SearXNG.new(
          base_url: @config.searxng_url,
          categories: @config.searxng_categories,
          timeout: @config.searxng_timeout
        )

        retriever = Retriever.new(
          backend: backend,
          deep_fetch: deep_fetch,
          top_n: @config.top_n_results
        )

        reranker = Reranker.new(embedder: @embedder)

        analyzer = QueryAnalyzer.new(llm: @llm_adapter)

        generator = GroundedGenerator.new(
          llm: @llm_adapter,
          max_tokens: @config.max_tokens
        )

        processor = PostProcessor.new

        Pipeline.new(
          analyzer: analyzer,
          retriever: retriever,
          reranker: reranker,
          generator: generator,
          processor: processor
        )
      end
    end
  end
end
