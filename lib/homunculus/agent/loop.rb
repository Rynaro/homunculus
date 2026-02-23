# frozen_string_literal: true

require "securerandom"
require "timeout"
require "digest"

module Homunculus
  module Agent
    class Loop
      include SemanticLogger::Loggable

      # Accepts either a single provider (backward compat for CLI) or a providers hash + router.
      # Optional models_router + stream_callback for CLI streaming via Models::Router.
      #
      # Single-provider mode:
      #   Loop.new(config:, provider:, tools:, prompt_builder:, audit:)
      #
      # Routing mode:
      #   Loop.new(config:, providers:, router:, tools:, prompt_builder:, audit:)
      #
      # Models router + streaming (CLI):
      #   Loop.new(config:, models_router:, stream_callback: ->(chunk) { print chunk }, tools:, prompt_builder:, audit:)
      #
      # Routing keyword args (passed via **routing):
      #   provider:       Single ModelProvider instance (CLI / single-provider mode)
      #   providers:      Hash of provider instances (multi-provider routing mode)
      #   router:         Agent::Router for model selection (routing mode)
      #   models_router:  Models::Router instance (CLI streaming mode)
      #   stream_callback: Lambda receiving streamed text chunks (models_router mode)
      def initialize(config:, tools:, prompt_builder:, audit:, **routing)
        @config         = config
        @router         = routing[:router]
        @models_router  = routing[:models_router]
        @stream_callback = routing[:stream_callback]
        @tools          = tools
        @prompt_builder = prompt_builder
        @audit          = audit

        # Support both single-provider (backward compat) and multi-provider (routing) modes
        if routing[:providers]
          @providers = routing[:providers]
        elsif routing[:provider]
          @providers = { ollama: routing[:provider] }
        elsif routing[:models_router]
          @providers = {}
        else
          raise ArgumentError, "Either provider:, providers:, or models_router: must be given"
        end
      end

      def run(user_message, session)
        system_prompt = @prompt_builder.build(session:)
        session.add_message(role: :user, content: user_message)

        max_turns = @config.agent.max_turns

        max_turns.times do |turn|
          logger.info("Agent turn", turn: turn + 1, max: max_turns, session_id: session.id)

          start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response, provider_used = complete_with_routing(session, system_prompt)
          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round

          session.track_usage(response.usage)

          @audit.log(
            action: "completion",
            session_id: session.id,
            model: response.model,
            tokens_in: response.usage&.input_tokens,
            tokens_out: response.usage&.output_tokens,
            stop_reason: response.stop_reason,
            provider: provider_used,
            duration_ms:
          )

          result = dispatch_turn(response, session)
          return result if result
        end

        AgentResult.error("Max turns (#{max_turns}) exceeded", session:)
      end

      # Resume after tool confirmation
      def confirm_tool(session)
        tool_call = session.pending_tool_call
        return AgentResult.error("No pending tool call", session:) unless tool_call

        session.pending_tool_call = nil

        result = execute_tool(tool_call, session, confirmed: true)
        session.add_tool_result(tool_call:, result:,
                                trust_level: @tools.trust_level(tool_call.name))

        # Continue the agent loop for the remaining turns
        continue(session)
      end

      # Deny a pending tool call
      def deny_tool(session)
        tool_call = session.pending_tool_call
        return AgentResult.error("No pending tool call", session:) unless tool_call

        session.pending_tool_call = nil

        # Add a denial result so the model knows the tool was rejected
        denial = Tools::Result.fail("Tool execution denied by user")
        session.add_tool_result(tool_call:, result: denial,
                                trust_level: @tools.trust_level(tool_call.name))

        continue(session)
      end

      private

      # ── Provider Routing ─────────────────────────────────────────────

      # Selects and calls the appropriate provider with routing, fallback, and quality detection.
      # Returns [response, provider_key] tuple.
      def complete_with_routing(session, system_prompt)
        return complete_via_models_router(session, system_prompt) if @models_router

        selection = select_provider(session)
        provider = @providers[selection.provider] || @providers.values.first

        begin
          response = attempt_completion(provider, session, system_prompt)
        rescue StandardError => e
          # Fallback: if local provider failed, try escalation
          fallback = fallback_provider(selection.provider)
          raise unless fallback

          logger.warn("Local provider failed, falling back to escalation",
                      error: e.message, session_id: session.id)
          response = attempt_completion(fallback, session, system_prompt)
          record_budget_usage(response)
          return [response, :anthropic]
        end

        # Record budget for paid providers
        record_budget_usage(response) if selection.provider == :anthropic

        # Quality check: if local response is low quality, try escalation
        if selection.provider == :ollama && low_quality_response?(response)
          reason = quality_issue(response)
          escalation = fallback_provider(:ollama)

          if escalation
            logger.info("Low quality local response, escalating to Claude",
                        reason:, session_id: session.id)
            response = attempt_completion(escalation, session, system_prompt)
            record_budget_usage(response)
            return [response, :anthropic]
          end
        end

        [response, selection.provider]
      end

      # Uses Models::Router (with optional streaming). Returns [response, provider_key].
      def complete_via_models_router(session, system_prompt)
        messages_with_system = [{ role: "system", content: system_prompt }, *session.messages_for_api]
        mr = @models_router.generate(
          messages: messages_with_system,
          tools: @tools.definitions,
          tier: nil,
          skill_name: nil,
          user_message: session.messages_for_api.select { |m| m[:role] == "user" }.last&.dig(:content).to_s,
          stream: @stream_callback ? true : false,
          &@stream_callback
        )
        response = models_response_to_loop_response(mr)
        [response, mr.provider || :ollama]
      end

      # Converts Models::Response to the shape the Loop expects (ModelProvider::Response duck type).
      def models_response_to_loop_response(mr)
        usage = mr.usage || {}
        tool_calls = (mr.tool_calls || []).map do |tc|
          h = tc.is_a?(Hash) ? tc : { id: tc[:id], name: tc[:name], arguments: tc[:arguments] }
          ModelProvider::ToolCall.new(
            id: h[:id] || SecureRandom.uuid,
            name: h[:name],
            arguments: h[:arguments] || {}
          )
        end
        ModelProvider::Response.new(
          content: mr.content,
          tool_calls: tool_calls,
          usage: ModelProvider::TokenUsage.new(
            input_tokens: usage[:prompt_tokens] || usage["prompt_tokens"] || 0,
            output_tokens: usage[:completion_tokens] || usage["completion_tokens"] || 0
          ),
          model: mr.model,
          stop_reason: (mr.finish_reason || :stop).to_s,
          raw_response: mr
        )
      end

      def select_provider(session)
        if @router
          @router.select_model(
            messages: session.messages_for_api,
            tools: @tools.definitions,
            session:
          )
        else
          # No router: use first (default) provider
          provider_key = @providers.keys.first
          ModelSelection.new(provider: provider_key, reason: :default)
        end
      end

      def attempt_completion(provider, session, system_prompt)
        provider.complete(
          messages: session.messages_for_api,
          tools: @tools.definitions,
          system: system_prompt,
          max_tokens: 4096,
          temperature: @config.models[:local]&.temperature || 0.7
        )
      end

      # Returns the escalation provider if available and budget allows, nil otherwise.
      def fallback_provider(current_provider)
        return nil unless current_provider == :ollama
        return nil unless @providers[:anthropic]
        return nil unless can_escalate?

        @providers[:anthropic]
      end

      def record_budget_usage(response)
        return unless @router&.budget && response.usage

        @router.budget.record_usage(
          model: response.model,
          input_tokens: response.usage.input_tokens,
          output_tokens: response.usage.output_tokens
        )
      end

      def can_escalate?
        return true unless @router&.budget

        @router.budget.can_use_claude?
      end

      # ── Quality Detection ────────────────────────────────────────────

      # Heuristics for detecting low-quality local model responses.
      def low_quality_response?(response)
        return false unless response

        content = response.content.to_s

        # Empty or whitespace-only response (except for tool_use which legitimately has no text)
        return true if content.strip.empty? && response.stop_reason != "tool_use"

        # Malformed tool call arguments (empty args for tools that should have them)
        if response.tool_calls&.any?
          has_malformed = response.tool_calls.any? do |tc|
            tc.arguments.nil? || (tc.arguments == {} && tc.name != "datetime_now")
          end
          return true if has_malformed
        end

        # Response cut off mid-sentence (claimed end_turn but no terminal punctuation)
        return true if response.stop_reason == "end_turn" && content.length > 20 && !content.strip.match?(/[.!?:}\])`'"\n]$/)

        false
      end

      # Identifies the specific quality issue for logging.
      def quality_issue(response)
        content = response.content.to_s
        return :empty_response if content.strip.empty?

        return :malformed_tool_call if response.tool_calls&.any? { |tc| tc.arguments.nil? || tc.arguments == {} }

        return :cut_off if content.length > 20 && !content.strip.match?(/[.!?:}\])`'"\n]$/)

        :unknown
      end

      # ── Turn Dispatch ────────────────────────────────────────────────

      # Dispatch a completed response based on its stop_reason.
      # Returns an AgentResult if the turn is terminal (completed, pending, error),
      # or nil if the loop should continue (tool results were added and another
      # LLM call is needed).
      def dispatch_turn(response, session)
        case response.stop_reason
        when "end_turn", "stop"
          session.add_message(role: :assistant, content: response.content)
          AgentResult.completed(response.content, session:)

        when "tool_use"
          session.add_message(role: :assistant, content: response.content, tool_calls: response.tool_calls)

          response.tool_calls.each do |tool_call|
            logger.info("Tool call requested", tool: tool_call.name, session_id: session.id)

            if @tools.requires_confirmation?(tool_call.name)
              session.pending_tool_call = tool_call
              return AgentResult.pending_confirmation(tool_call, session:)
            end

            result = execute_tool(tool_call, session)
            session.add_tool_result(tool_call:, result:,
                                    trust_level: @tools.trust_level(tool_call.name))
          end

          nil # continue the loop

        when "max_tokens"
          session.add_message(role: :assistant, content: response.content)
          AgentResult.completed(
            "#{response.content}\n\n⚠️ Response was truncated due to token limit.",
            session:
          )

        else
          logger.warn("Unknown stop reason", stop_reason: response.stop_reason, session_id: session.id)
          session.add_message(role: :assistant, content: response.content)
          AgentResult.completed(response.content, session:)
        end
      end

      # ── Continue & Tool Execution ─────────────────────────────────────

      def continue(session)
        system_prompt = @prompt_builder.build(session:)
        remaining_turns = @config.agent.max_turns - session.turn_count

        remaining_turns.times do
          response, _provider = complete_with_routing(session, system_prompt)
          session.track_usage(response.usage)

          result = dispatch_turn(response, session)
          return result if result
        end

        AgentResult.error("Max turns (#{@config.agent.max_turns}) exceeded", session:)
      end

      def execute_tool(tool_call, session, confirmed: false)
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        @audit.log(
          action: "tool_exec_start",
          tool: tool_call.name,
          input_hash: Digest::SHA256.hexdigest(tool_call.arguments.to_json)[0..15],
          session_id: session.id,
          confirmed:
        )

        result = Timeout.timeout(@config.agent.max_execution_time_seconds) do
          @tools.execute(
            name: tool_call.name,
            arguments: tool_call.arguments,
            session:
          )
        end

        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round

        @audit.log(
          action: "tool_exec_end",
          tool: tool_call.name,
          output_hash: Digest::SHA256.hexdigest(result.to_s)[0..15],
          success: result.success,
          session_id: session.id,
          duration_ms:
        )

        result
      rescue Timeout::Error
        logger.error("Tool execution timed out",
                     tool: tool_call.name,
                     timeout: @config.agent.max_execution_time_seconds,
                     session_id: session.id)
        Tools::Result.fail("Tool execution timed out after #{@config.agent.max_execution_time_seconds}s")
      rescue Tools::UnknownToolError => e
        logger.error("Unknown tool", tool: tool_call.name, session_id: session.id)
        Tools::Result.fail(e.message)
      rescue StandardError => e
        logger.error("Tool execution failed",
                     tool: tool_call.name,
                     error: e.message,
                     session_id: session.id)
        Tools::Result.fail("Tool error: #{e.message}")
      end
    end

    # Result type for the agent loop
    AgentResult = Data.define(:status, :response, :error, :pending_tool_call, :session) do
      def self.completed(response, session:)
        new(status: :completed, response:, error: nil, pending_tool_call: nil, session:)
      end

      def self.pending_confirmation(tool_call, session:)
        new(status: :pending_confirmation, response: nil, error: nil, pending_tool_call: tool_call, session:)
      end

      def self.error(error, session:)
        new(status: :error, response: nil, error:, pending_tool_call: nil, session:)
      end

      def completed? = status == :completed
      def pending? = status == :pending_confirmation
      def error? = status == :error
    end
  end
end
