# frozen_string_literal: true

module Homunculus
  module Tools
    # Strategy evaluator stub for adaptive web mode selection.
    # Returns recommended_mode (:http | :no_tool | :research) and rationale.
    # Phase 1: heuristic-based; Phase 3 will enhance with learned/context-aware logic.
    module WebStrategy
      MODE_HTTP = :http
      MODE_NO_TOOL = :no_tool
      MODE_RESEARCH = :research

      # Task hint keywords that suggest each mode
      FETCH_INDICATORS = %w[fetch get retrieve load fetch page url content].freeze
      ENOUGH_INDICATORS = %w[already have enough sufficient no need skip don't need].freeze
      SEARCH_INDICATORS = %w[search find discover lookup explore browse].freeze

      class << self
        # @param url [String] URL to consider fetching
        # @param task_hint [String, nil] Optional hint about the user's task
        # @return [Hash] { recommended_mode: Symbol, rationale: String }
        def recommend(url: nil, task_hint: nil)
          hint_lower = (task_hint || "").downcase

          if url.to_s.strip.empty?
            return {
              recommended_mode: MODE_NO_TOOL,
              rationale: "No URL provided; no web fetch needed"
            }
          end

          if suggests_no_tool?(hint_lower)
            return {
              recommended_mode: MODE_NO_TOOL,
              rationale: "Task hint suggests content already available"
            }
          end

          if suggests_research?(hint_lower)
            return {
              recommended_mode: MODE_RESEARCH,
              rationale: "Task suggests discovery/search; web_research may be better"
            }
          end

          if suggests_fetch?(hint_lower) || valid_url?(url)
            return {
              recommended_mode: MODE_HTTP,
              rationale: "Valid URL and task suggests fetch; use web_fetch or web_extract"
            }
          end

          { recommended_mode: MODE_HTTP, rationale: "Default to HTTP fetch for given URL" }
        end

        def suggests_no_tool?(hint)
          ENOUGH_INDICATORS.any? { |kw| hint.include?(kw) }
        end

        def suggests_research?(hint)
          SEARCH_INDICATORS.any? { |kw| hint.include?(kw) }
        end

        def suggests_fetch?(hint)
          FETCH_INDICATORS.any? { |kw| hint.include?(kw) }
        end

        def valid_url?(url)
          u = url.to_s.strip
          return false if u.empty?
          u.start_with?("http://", "https://")
        end
      end
    end
  end
end
