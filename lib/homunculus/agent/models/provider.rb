# frozen_string_literal: true

module Homunculus
  module Agent
    module Models
      # Abstract base class for LLM providers.
      # All providers must implement: #generate, #generate_stream, #available?, #model_loaded?
      class Provider
        attr_reader :name, :config

        def initialize(name:, config:)
          @name = name
          @config = config
          @logger = SemanticLogger[self.class.name]
        end

        # Synchronous completion. Returns a normalized Hash.
        # @param messages [Array<Hash>] OpenAI-style message array [{role:, content:}]
        # @param model [String] Model identifier
        # @param tools [Array<Hash>, nil] Tool definitions (JSON Schema format)
        # @param temperature [Float] Sampling temperature
        # @param max_tokens [Integer] Maximum tokens to generate
        # @return [Hash] Normalized response hash
        def generate(messages:, model:, tools: nil, temperature: 0.7, max_tokens: 4096, context_window: nil)
          raise NotImplementedError, "#{self.class}#generate must be implemented"
        end

        # Streaming completion. Yields chunks to block.
        # @yield [String] Each text chunk as it arrives
        # @return [Hash] Final normalized response hash
        def generate_stream(messages:, model:, tools: nil, temperature: 0.7, max_tokens: 4096, context_window: nil, &block)
          raise NotImplementedError, "#{self.class}#generate_stream must be implemented"
        end

        # Is this provider reachable and healthy?
        # @return [Boolean]
        def available?
          raise NotImplementedError, "#{self.class}#available? must be implemented"
        end

        # Is a specific model currently loaded/ready?
        # @param model [String]
        # @return [Boolean]
        def model_loaded?(model)
          raise NotImplementedError, "#{self.class}#model_loaded? must be implemented"
        end
      end
    end
  end
end
