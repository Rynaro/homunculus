# frozen_string_literal: true

module Homunculus
  module Tools
    class MemoryCurate < Base
      tool_name "memory_curate"
      description "Permanently update a section of MEMORY.md with a durable fact about the user. " \
                  "Use only for facts that should persist across ALL future sessions. " \
                  "Requires user confirmation."
      trust_level :mixed
      requires_confirmation true

      parameter :section, type: :string,
                          description: "Section heading to write under (e.g. 'About My Human', 'Preferences')"
      parameter :content, type: :string,
                          description: "The durable fact or bullet list to store under this section"
      parameter :mode, type: :string,
                       description: "How to update: 'replace' replaces the whole section, 'append' adds to it",
                       required: false,
                       enum: %w[replace append]

      def initialize(memory_store:)
        @memory_store = memory_store
      end

      def execute(arguments:, session:)
        section = arguments[:section]
        content = arguments[:content]
        mode = arguments.fetch(:mode, "replace")

        return Result.fail("Missing required parameter: section") unless section && !section.strip.empty?
        return Result.fail("Missing required parameter: content") unless content && !content.strip.empty?

        final_content = if mode == "append"
                          existing = @memory_store.read_section(section.strip)
                          existing ? "#{existing}\n#{content.strip}" : content.strip
                        else
                          content.strip
                        end

        @memory_store.save_long_term(key: section.strip, content: final_content)
        Result.ok("MEMORY.md updated: section '#{section}' (#{mode})")
      rescue StandardError => e
        Result.fail("Memory curate failed: #{e.message}")
      end
    end
  end
end
