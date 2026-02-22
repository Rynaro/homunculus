# frozen_string_literal: true

module Homunculus
  module Tools
    class MemorySave < Base
      tool_name "memory_save"
      description "Save a fact or note to long-term memory (MEMORY.md). Use a descriptive key as the category heading."
      trust_level :trusted
      requires_confirmation false

      parameter :key, type: :string,
                      description: "Category heading for this memory (e.g. 'User Preferences', 'Project Architecture')"
      parameter :content, type: :string, description: "The fact or note to save"

      def initialize(memory_store:)
        @memory_store = memory_store
      end

      def execute(arguments:, session:)
        key = arguments[:key]
        content = arguments[:content]

        return Result.fail("Missing required parameter: key") unless key && !key.strip.empty?
        return Result.fail("Missing required parameter: content") unless content && !content.strip.empty?

        @memory_store.save_long_term(key: key.strip, content: content.strip)
        Result.ok("Saved to MEMORY.md under '#{key}'")
      rescue StandardError => e
        Result.fail("Memory save failed: #{e.message}")
      end
    end
  end
end
