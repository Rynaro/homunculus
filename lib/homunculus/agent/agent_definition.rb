# frozen_string_literal: true

module Homunculus
  module Agent
    # Immutable definition of a specialized agent, loaded from workspace/agents/<name>/.
    # Data objects are frozen by default, making them Ractor-safe (shareable).
    AgentDefinition = Data.define(:name, :soul, :tools_config, :model_preference, :allowed_tools) do
      def to_s
        "Agent(#{name})"
      end

      # Returns a Ractor-shareable version of this definition.
      # Data objects are already frozen, but we ensure deep shareability.
      def to_shareable
        Ractor.make_shareable(self)
      rescue TypeError
        # Fallback: reconstruct with frozen strings
        self.class.new(
          name: name.frozen? ? name : name.dup.freeze,
          soul: soul.frozen? ? soul : soul.dup.freeze,
          tools_config: tools_config&.frozen? ? tools_config : tools_config&.dup&.freeze,
          model_preference: model_preference,
          allowed_tools: allowed_tools.frozen? ? allowed_tools : allowed_tools.map(&:freeze).freeze
        )
      end

      # Parse model preference from SOUL.md content.
      # Looks for "## Model Preference" section and extracts hints.
      def self.extract_model_preference(soul_content)
        return :auto unless soul_content

        lower = soul_content.downcase
        return :escalation if lower.include?("prefer claude")
        return :local if lower.include?("prefer local")

        :auto
      end

      # Parse allowed tools from TOOLS.md content.
      # Extracts tool names from "## Allowed Tools" section.
      def self.extract_allowed_tools(tools_content)
        return [] unless tools_content

        tools_content.scan(/`(\w+)`/).flatten.uniq
      end
    end
  end
end
