# frozen_string_literal: true

module Homunculus
  module Tools
    # Failure taxonomy for web fetch/extract operations.
    # Used in web_fetch and web_extract to return structured failure metadata.
    module WebClassification
      # Failure reasons for web operations
      SUCCESS = "success"
      BLOCKED_BOT = "blocked_bot"
      INCOMPLETE_HTML = "incomplete_html"
      JS_REQUIRED = "js_required"
      AUTH_REQUIRED = "auth_required"
      RATE_LIMITED = "rate_limited"
      TIMEOUT = "timeout"
      EXTRACTION_MISMATCH = "extraction_mismatch"

      FAILURE_REASONS = [
        SUCCESS, BLOCKED_BOT, INCOMPLETE_HTML, JS_REQUIRED,
        AUTH_REQUIRED, RATE_LIMITED, TIMEOUT, EXTRACTION_MISMATCH
      ].freeze

      # Body indicators that suggest auth/paywall/CAPTCHA (phrases to avoid false positives)
      AUTH_INDICATORS = [
        "log in", "sign in", "log in to", "sign in to",
        "captcha", "recaptcha", "hcaptcha",
        "paywall", "subscribe now", "subscribe to",
        "access denied", "please authenticate", "please log in", "please sign in"
      ].freeze

      # Minimum body size (chars) for HTML; below this we consider it skeleton/JS-rendered
      MIN_BODY_THRESHOLD = 100

      class << self
        # Classify an HTTP response into failure reason and response_classification.
        # @param status [Integer] HTTP status code
        # @param body [String] Response body (HTML or text)
        # @param timeout [Boolean] Whether the request timed out
        # @return [Hash] { failure_reason:, response_classification: }
        def classify(status:, body:, timeout: false)
          return { failure_reason: TIMEOUT, response_classification: TIMEOUT } if timeout

          case status
          when 403
            { failure_reason: BLOCKED_BOT, response_classification: BLOCKED_BOT }
          when 429
            { failure_reason: RATE_LIMITED, response_classification: RATE_LIMITED }
          when 200
            classify_200_body(body || "")
          else
            { failure_reason: BLOCKED_BOT, response_classification: BLOCKED_BOT }
          end
        end

        def classify_200_body(body)
          text = body.to_s.downcase
          return { failure_reason: INCOMPLETE_HTML, response_classification: INCOMPLETE_HTML } if body.length < MIN_BODY_THRESHOLD
          return { failure_reason: AUTH_REQUIRED, response_classification: AUTH_REQUIRED } if auth_indicators_match?(text)
          return { failure_reason: JS_REQUIRED, response_classification: JS_REQUIRED } if js_required?(body)

          { failure_reason: SUCCESS, response_classification: SUCCESS }
        end

        def auth_indicators_match?(text)
          AUTH_INDICATORS.any? { |phrase| text.include?(phrase) }
        end

        def js_required?(body)
          # Minimal skeleton or loading placeholder
          body.to_s.strip =~ /\A\s*<(?:html|!DOCTYPE|script|div)[\s>]/i && body.length < 500
        end
      end
    end
  end
end
