# frozen_string_literal: true

module Homunculus
  module Interfaces
    module SAGReachability
      def sag_backend_available?(logger, config)
        backend = SAG::SearchBackend::SearXNG.new(
          base_url: config.sag.searxng_url, categories: config.sag.searxng_categories,
          timeout: config.sag.searxng_timeout
        )
        return true if backend.available?

        logger.warn(
          "SAG web_research tool not registered — SearXNG not reachable",
          searxng_url: config.sag.searxng_url
        )
        false
      rescue StandardError => e
        logger.warn(
          "SAG web_research availability check failed",
          error: e.message,
          searxng_url: config.sag.searxng_url
        )
        false
      end
    end
  end
end
