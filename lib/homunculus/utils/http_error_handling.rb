# frozen_string_literal: true

module Homunculus
  module Utils
    # Shared helper for detecting HTTPX connection and error responses.
    # Both OllamaProvider and AnthropicProvider need the same check:
    # an HTTPX::ErrorResponse lacks .status and carries a .error message.
    #
    # Include this module in any class that makes HTTPX requests:
    #
    #   include Utils::HttpErrorHandling
    #
    # Then call: raise_if_error!(response, "ProviderName")
    # raising either ProviderError (in Models namespace) or a plain RuntimeError.
    module HttpErrorHandling
      private

      # Raises if response is an HTTPX::ErrorResponse or lacks a #status method.
      # @param response [Object] the raw HTTPX response
      # @param provider [String] provider name used in the error message
      # @param error_class [Class] error class to raise (default: RuntimeError)
      def raise_if_http_error!(response, provider, error_class: RuntimeError)
        unless response.respond_to?(:status)
          msg = response.respond_to?(:error) && response.error ? response.error.message : "connection failed"
          raise error_class, "#{provider} connection error: #{msg}"
        end
        return unless response.is_a?(HTTPX::ErrorResponse)

        raise error_class, "#{provider} connection error: #{response.error.message}"
      end
    end
  end
end
