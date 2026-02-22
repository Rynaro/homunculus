# frozen_string_literal: true

module Homunculus
  module Tools
    class Registry
      def initialize
        @tools = {}
      end

      def register(tool)
        raise ArgumentError, "Tool must be a Tools::Base instance" unless tool.is_a?(Tools::Base)

        @tools[tool.name] = tool
      end

      def [](name)
        @tools[name.to_s]
      end

      def definitions
        @tools.values.map(&:definition)
      end

      def definitions_for_prompt
        @tools.values.map(&:prompt_description).join("\n\n")
      end

      def execute(name:, arguments:, session:)
        tool = @tools.fetch(name.to_s) { raise UnknownToolError, "Unknown tool: #{name}" }
        tool.execute(arguments: normalize_arguments(arguments), session:)
      end

      def requires_confirmation?(name)
        @tools[name.to_s]&.requires_confirmation || false
      end

      def trust_level(name)
        @tools[name.to_s]&.trust_level || :untrusted
      end

      def tool_names
        @tools.keys
      end

      def size
        @tools.size
      end

      def empty?
        @tools.empty?
      end

      private

      def normalize_arguments(arguments)
        case arguments
        when Hash
          arguments.transform_keys(&:to_sym)
        when String
          JSON.parse(arguments, symbolize_names: true)
        else
          {}
        end
      rescue JSON::ParserError
        {}
      end
    end
  end
end
