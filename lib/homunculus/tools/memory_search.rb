# frozen_string_literal: true

module Homunculus
  module Tools
    class MemorySearch < Base
      tool_name "memory_search"
      description "Search the memory system for relevant context, past conversations, and stored facts."
      trust_level :trusted

      parameter :query, type: :string, description: "The search query — describe what you're looking for"
      parameter :limit, type: :integer, description: "Maximum number of results to return (default: 5)",
                        required: false

      def initialize(memory_store:)
        @memory_store = memory_store
      end

      def execute(arguments:, session:)
        query = arguments[:query]
        return Result.fail("Missing required parameter: query") unless query && !query.strip.empty?

        limit = arguments.fetch(:limit, 5).to_i.clamp(1, 20)

        results = @memory_store.search(query, limit:)

        if results.empty?
          Result.ok("No relevant memories found for: #{query}")
        else
          formatted = results.map.with_index(1) do |r, i|
            source = Pathname.new(r.source).basename.to_s
            "#{i}. [#{source}] #{r.content.strip}"
          end.join("\n\n")

          Result.ok(formatted, count: results.size)
        end
      rescue StandardError => e
        Result.fail("Memory search failed: #{e.message}")
      end
    end
  end
end
