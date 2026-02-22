# frozen_string_literal: true

module Homunculus
  module Tools
    class MemoryDailyLog < Base
      tool_name "memory_daily_log"
      description "Append a note to today's daily log file (memory/YYYY-MM-DD.md)."
      trust_level :trusted
      requires_confirmation false

      parameter :content, type: :string, description: "The note to append to today's log"
      parameter :heading, type: :string, description: "Optional heading for the entry",
                          required: false

      def initialize(memory_store:)
        @memory_store = memory_store
      end

      def execute(arguments:, session:)
        content = arguments[:content]
        heading = arguments[:heading]

        return Result.fail("Missing required parameter: content") unless content && !content.strip.empty?

        @memory_store.append_daily_log(content: content.strip, heading: heading&.strip)
        Result.ok("Appended to daily log for #{Date.today.iso8601}")
      rescue StandardError => e
        Result.fail("Daily log append failed: #{e.message}")
      end
    end
  end
end
