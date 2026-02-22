# frozen_string_literal: true

require "json"

module Homunculus
  module Tools
    class Base
      class << self
        def tool_name(name = nil)
          if name
            @tool_name = name.to_s
          else
            @tool_name || self.name.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
          end
        end

        def description(desc = nil)
          if desc
            @description = desc
          else
            @description || "No description provided"
          end
        end

        def requires_confirmation(value = nil)
          if value.nil?
            @requires_confirmation || false
          else
            @requires_confirmation = value
          end
        end

        def trust_level(value = nil)
          if value.nil?
            @trust_level || :trusted
          else
            @trust_level = value
          end
        end

        def parameter(name, type:, description: nil, required: true, enum: nil)
          @parameters ||= {}
          @parameters[name.to_sym] = {
            type: type.to_s,
            description:,
            required:,
            enum:
          }.compact
        end

        def parameters
          @parameters || {}
        end
      end

      # Instance methods — delegate to class-level DSL
      def name = self.class.tool_name
      def description = self.class.description
      def parameters = self.class.parameters
      def requires_confirmation = self.class.requires_confirmation
      def trust_level = self.class.trust_level

      def execute(arguments:, session:)
        raise NotImplementedError, "#{self.class}#execute must be implemented"
      end

      # Returns a provider-agnostic tool definition hash
      def definition
        {
          name:,
          description:,
          parameters: json_schema_parameters,
          requires_confirmation:,
          trust_level:
        }
      end

      # Human-readable tool description for system prompt
      def prompt_description
        params_desc = parameters.map do |pname, pdef|
          req = pdef[:required] ? " (required)" : " (optional)"
          "    - #{pname} [#{pdef[:type]}]#{req}: #{pdef[:description]}"
        end.join("\n")

        "**#{name}**: #{description}\n#{params_desc}"
      end

      # Returns JSON Schema-compatible parameter definition
      def json_schema_parameters
        props = {}
        required = []

        parameters.each do |pname, pdef|
          prop = { type: pdef[:type] }
          prop[:description] = pdef[:description] if pdef[:description]
          prop[:enum] = pdef[:enum] if pdef[:enum]
          props[pname.to_s] = prop
          required << pname.to_s if pdef[:required]
        end

        {
          type: "object",
          properties: props,
          required:
        }
      end
    end

    # Unified result type for tool executions
    Result = Data.define(:success, :output, :error, :metadata) do
      def self.ok(output, **metadata)
        new(success: true, output: output.to_s, error: nil, metadata:)
      end

      def self.fail(error, **metadata)
        new(success: false, output: nil, error: error.to_s, metadata:)
      end

      def to_s
        success ? output : "Error: #{error}"
      end
    end

    class UnknownToolError < StandardError; end
  end
end
