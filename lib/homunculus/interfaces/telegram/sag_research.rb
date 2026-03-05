# frozen_string_literal: true

module Homunculus
  module Interfaces
    class Telegram
      # SAG pipeline factory methods for building web_research tool instances.
      module SAGResearch
        private

        def build_sag_pipeline_factory
          sag = @config.sag
          lambda { |deep_fetch: false|
            backend = SAG::SearchBackend::SearXNG.new(
              base_url: sag.searxng_url,
              categories: sag.searxng_categories,
              timeout: sag.searxng_timeout
            )
            retriever = SAG::Retriever.new(backend: backend, deep_fetch: deep_fetch, top_n: sag.top_n_results)
            embedder = build_sag_embedder
            reranker = SAG::Reranker.new(embedder: sag.reranking_strategy == "embedding" ? embedder : nil)
            llm = build_sag_llm
            generator = SAG::GroundedGenerator.new(llm: llm, max_tokens: sag.max_tokens)
            processor = SAG::PostProcessor.new
            analyzer = SAG::QueryAnalyzer.new(llm: llm)
            SAG::Pipeline.new(
              analyzer: analyzer, retriever: retriever, reranker: reranker,
              generator: generator, processor: processor
            )
          }
        end

        def build_sag_embedder
          local_config = @config.models[:local]
          return nil unless local_config&.base_url

          Memory::Embedder.new(base_url: local_config.base_url, model: @config.memory.embedding_model)
        end

        def build_sag_llm
          providers = @providers
          lambda { |prompt, max_tokens: 1024|
            last_error = nil

            %i[ollama anthropic].each do |provider_key|
              provider = providers[provider_key]
              next unless provider

              begin
                response = provider.complete(
                  messages: [{ role: "user", content: prompt }],
                  system: "You are a research assistant.",
                  max_tokens: max_tokens,
                  temperature: 0.2
                )
                return response.content.to_s
              rescue StandardError => e
                last_error = e
                SemanticLogger["SAGResearch"].warn(
                  "SAG LLM call failed, trying next provider",
                  provider: provider_key, error: e.message
                )
              end
            end

            raise last_error || RuntimeError.new("No LLM providers available for SAG pipeline")
          }
        end
      end
    end
  end
end
