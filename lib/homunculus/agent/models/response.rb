# frozen_string_literal: true

module Homunculus
  module Agent
    module Models
      # Unified response object for all LLM providers.
      # Immutable value type using Ruby's Data.define.
      Response = Data.define(
        :content,           # String — the text response
        :tool_calls,        # Array<Hash> — [{name:, arguments:}] or empty
        :model,             # String — actual model used
        :provider,          # Symbol — :ollama or :anthropic
        :tier,              # Symbol — :whisper, :workhorse, :coder, :thinker, :cloud_*
        :usage,             # Hash — {prompt_tokens:, completion_tokens:, total_tokens:}
        :latency_ms,        # Integer — total request time
        :cost_usd,          # Float — estimated cost (0.0 for local)
        :finish_reason,     # Symbol — :stop, :tool_use, :length, :error
        :escalated_from,    # Symbol or nil — if this was an escalation, what tier it came from
        :metadata           # Hash — provider-specific extra data
      ) do
        def local? = provider == :ollama
        def cloud? = provider == :anthropic
        def tool_use? = tool_calls.is_a?(Array) && !tool_calls.empty?
        def escalated? = !escalated_from.nil?

        def to_audit_hash
          {
            model:, provider:, tier:,
            usage:, latency_ms:, cost_usd:,
            finish_reason:, escalated_from:,
            timestamp: Time.now.iso8601
          }
        end
      end
    end
  end
end
