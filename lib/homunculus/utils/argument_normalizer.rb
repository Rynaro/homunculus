# frozen_string_literal: true

module Homunculus
  module Utils
    # Shared helper for coercing LLM tool-call arguments into a symbol-keyed Hash.
    # Arguments may arrive as a Hash, a JSON string, or nil from different providers.
    #
    # Include this module in any class that parses tool-call arguments:
    #
    #   include Utils::ArgumentNormalizer
    #
    # Then call: normalize_arguments(raw_args)
    module ArgumentNormalizer
      private

      # Coerce raw tool-call arguments to a symbol-keyed Hash.
      # Accepts Hash (symbol- or string-keyed), JSON String, or nil.
      # Returns {} on parse failure or unrecognised input type.
      def normalize_arguments(args)
        case args
        when Hash   then args.transform_keys(&:to_sym)
        when String then JSON.parse(args, symbolize_names: true)
        else {}
        end
      rescue JSON::ParserError
        {}
      end
    end
  end
end
