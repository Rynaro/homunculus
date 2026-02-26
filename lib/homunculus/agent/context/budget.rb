# frozen_string_literal: true

module Homunculus
  module Agent
    module Context
      class Budget
        SECTIONS = %i[system_prompt skills memory conversation reserve].freeze

        # @param context_window [Integer] total context window in tokens
        # @param config [Homunculus::ContextConfig, nil] percentage overrides
        def initialize(context_window:, config: nil)
          @context_window = context_window
          @percentages = {
            system_prompt: config&.system_prompt_pct || 0.30,
            skills: config&.skills_pct || 0.10,
            memory: config&.memory_pct || 0.15,
            conversation: config&.conversation_pct || 0.40,
            reserve: config&.reserve_pct || 0.05
          }
        end

        attr_reader :context_window

        # @param section [Symbol] one of SECTIONS
        # @return [Integer] token budget for the section
        def tokens_for(section)
          raise ArgumentError, "Unknown section: #{section}" unless SECTIONS.include?(section)

          (@context_window * @percentages[section]).floor
        end
      end
    end
  end
end
