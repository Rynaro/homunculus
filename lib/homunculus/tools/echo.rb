# frozen_string_literal: true

module Homunculus
  module Tools
    class Echo < Base
      tool_name "echo"
      description "Returns the input text unchanged. Useful for testing the agent loop."
      trust_level :trusted

      parameter :text, type: :string, description: "The text to echo back"

      def execute(arguments:, session:)
        text = arguments[:text]
        return Result.fail("Missing required parameter: text") unless text

        Result.ok(text)
      end
    end
  end
end
