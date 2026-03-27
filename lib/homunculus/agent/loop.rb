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
        @config              = config
        @router              = routing[:router]
        @models_router       = routing[:models_router]
        @stream_callback     = routing[:stream_callback]
        @status_callback     = routing[:status_callback]
        @familiars_dispatcher = routing[:familiars_dispatcher]
        @tools               = tools
        @prompt_builder      = prompt_builder
        @audit               = audit

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
        @context_budget = build_context_budget
        system_prompt = @prompt_builder.build(session:, context_budget: @context_budget)
        session.add_message(role: :user, content: user_message)

        max_turns = @config.agent.max_turns

        consumed_turns = 0
        max_turns.times do |turn|
          break if turn + consumed_turns >= max_turns

          consumed_turns += maybe_compact(session, system_prompt)

          logger.info("Agent turn", turn: turn + consumed_turns + 1, max: max_turns, session_id: session.id)

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

        notify_familiars_event(:error, session:, detail: "Max turns (#{max_turns}) exceeded")
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
        windowed = apply_context_window(session.messages_for_api)
        messages_with_system = [{ role: "system", content: system_prompt }, *windowed]
        tier = resolve_session_tier(session)
        mr = @models_router.generate(
          messages: messages_with_system,
          tools: @tools.definitions,
          tier: tier,
          skill_name: nil,
          user_message: session.messages_for_api.select { |m| m[:role] == "user" }.last&.dig(:content).to_s,
          stream: @stream_callback ? true : false,
          &@stream_callback
        )
        # When routing is on and a forced_tier was used for the first call, clear it now
        if session.routing_enabled && session.forced_tier && !session.first_message_sent
          session.first_message_sent = true
          session.forced_tier = nil
        end
        response = models_response_to_loop_response(mr)
        [response, mr.provider || :ollama]
      end

      # Determines the tier override to pass to models_router#generate based on session state.
      # Returns nil when routing should determine tier normally.
      def resolve_session_tier(session)
        return nil unless session.respond_to?(:forced_tier) && session.forced_tier
        # Routing ON: use forced_tier on first call only; return nil once first_message_sent
        return nil if session.routing_enabled && session.first_message_sent

        session.forced_tier
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
        windowed = apply_context_window(session.messages_for_api)
        provider.complete(
          messages: windowed,
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
        tier, model, escalated_from = tier_metadata_from_response(response)
        ctx_window = context_window_for_response(response)

        case response.stop_reason
        when "end_turn", "stop"
          session.add_message(role: :assistant, content: response.content)
          notify_familiars_event(:session_complete, session:)
          AgentResult.completed(response.content, session:, tier:, model:, escalated_from:, context_window: ctx_window)

        when "tool_use"
          session.add_message(role: :assistant, content: response.content, tool_calls: response.tool_calls)

          response.tool_calls.each do |tool_call|
            logger.info("Tool call requested", tool: tool_call.name, session_id: session.id)

            if @tools.requires_confirmation?(tool_call.name)
              session.pending_tool_call = tool_call
              notify_familiars_event(:confirmation_needed, session:, tool_name: tool_call.name)
              return AgentResult.pending_confirmation(tool_call, session:, context_window: ctx_window)
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
            session:, tier:, model:, escalated_from:, context_window: ctx_window
          )

        else
          logger.warn("Unknown stop reason", stop_reason: response.stop_reason, session_id: session.id)
          session.add_message(role: :assistant, content: response.content)
          AgentResult.completed(response.content, session:, tier:, model:, escalated_from:, context_window: ctx_window)
        end
      end

      def tier_metadata_from_response(response)
        raw = response.raw_response
        return [nil, nil, nil] unless raw.respond_to?(:tier)

        [
          raw.tier&.to_s,
          raw.respond_to?(:model) ? raw.model : nil,
          raw.respond_to?(:escalated_from) ? raw.escalated_from&.to_s : nil
        ]
      end

      # Returns the context window size for the given response.
      # Prefers the tier config when routing through models_router; falls back to config.
      def context_window_for_response(response)
        raw = response.raw_response
        if raw.respond_to?(:tier) && raw.tier && @models_router
          tier_str = raw.tier.to_s
          tier_cfg = @models_router.config.dig("tiers", tier_str)
          return tier_cfg["context_window"].to_i if tier_cfg&.key?("context_window")
        end
        resolve_context_window
      end

      # ── Continue & Tool Execution ─────────────────────────────────────

      def continue(session)
        @context_budget ||= build_context_budget
        system_prompt = @prompt_builder.build(session:, context_budget: @context_budget)
        remaining_turns = @config.agent.max_turns - session.turn_count

        consumed_turns = 0
        remaining_turns.times do |turn|
          break if turn + consumed_turns >= remaining_turns

          consumed_turns += maybe_compact(session, system_prompt)

          response, _provider = complete_with_routing(session, system_prompt)
          session.track_usage(response.usage)

          result = dispatch_turn(response, session)
          return result if result
        end

        AgentResult.error("Max turns (#{@config.agent.max_turns}) exceeded", session:)
      end

      # ── Context Intelligence ─────────────────────────────────────────

      # Build a context budget from the resolved model tier's context_window.
      def build_context_budget
        context_window = resolve_context_window
        return nil unless context_window

        Context::Budget.new(context_window:, config: @config.agent.context)
      end

      # Determine context_window from config. Prefers local model tier.
      def resolve_context_window
        @config.models[:local]&.context_window
      end

      # Apply sliding window to messages if budget and windowing are enabled.
      def apply_context_window(messages)
        return messages unless @context_budget
        return messages unless @config.agent.context.enable_windowing

        context_window.apply(messages)
      end

      def context_window
        @context_window ||= Context::Window.new(
          budget: @context_budget,
          compressor: context_compressor
        )
      end

      # Lazy-init compactor only when models_router exists (needs compressor for summarization).
      def context_compactor
        return nil unless @models_router
        return nil unless @context_budget

        @context_compactor ||= Context::Compactor.new(
          config: @config.agent.context,
          budget: @context_budget,
          compressor: context_compressor || Context::Compressor.new
        )
      end

      # Run proactive compaction if conversation is approaching context limits.
      # Returns the number of turns consumed (0 or 1).
      def maybe_compact(session, system_prompt)
        compactor = context_compactor
        return 0 unless compactor
        return 0 unless compactor.needs_compaction?(session.messages_for_api)

        logger.info("Compaction triggered — injecting flush turn", session_id: session.id)

        # Inject flush message and run one LLM turn
        flush_msg = compactor.flush_message
        session.add_message(role: flush_msg[:role], content: flush_msg[:content])

        response, _provider = complete_with_routing(session, system_prompt)
        session.track_usage(response.usage)
        session.add_message(role: :assistant, content: response.content, tool_calls: response.tool_calls)

        # Execute only trusted (non-confirmation-required) tool calls from the flush turn
        if response.tool_calls&.any?
          response.tool_calls.each do |tool_call|
            next if @tools.requires_confirmation?(tool_call.name)

            result = execute_tool(tool_call, session)
            session.add_tool_result(tool_call:, result:,
                                    trust_level: @tools.trust_level(tool_call.name))
          end
        end

        # Compact the conversation
        compacted = compactor.compact(session.messages_for_api)
        session.replace_messages(compacted)

        @audit.log(
          action: "context_compaction",
          session_id: session.id,
          messages_before: session.messages.size,
          messages_after: compacted.size
        )

        1 # consumed one turn
      end

      # Lazy-init compressor only when models_router exists.
      def context_compressor
        return nil unless @models_router

        @context_compressor ||= Context::Compressor.new(models_router: @models_router)
      end

      # ── Tool Execution ─────────────────────────────────────────────────

      def execute_tool(tool_call, session, confirmed: false)
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        @audit.log(
          action: "tool_exec_start",
          tool: tool_call.name,
          input_hash: Digest::SHA256.hexdigest(tool_call.arguments.to_json)[0..15],
          session_id: session.id,
          confirmed:
        )

        @status_callback&.call(:tool_start, tool_call.name)

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
      ensure
        @status_callback&.call(:tool_end, tool_call.name)
      end

      # ── Familiars Notifications ───────────────────────────────────

      # Dispatch a Familiars notification for a named event, if the dispatcher
      # is configured and the event is in the notify_on list.
      # Failures are logged and never propagate — agent loop is never blocked.
      def notify_familiars_event(event, session: nil, tool_name: nil, detail: nil)
        return unless @familiars_dispatcher
        return unless familiars_event_enabled?(event)

        title, message, priority = build_familiars_notification(event, session:, tool_name:, detail:)
        @familiars_dispatcher.notify(title:, message:, priority:)
      rescue StandardError => e
        logger.warn("Familiars event notification failed", event:, error: e.message)
      end

      def familiars_event_enabled?(event)
        @config.familiars.notify_on.include?(event.to_s)
      rescue StandardError
        false
      end

      def build_familiars_notification(event, session: nil, tool_name: nil, detail: nil)
        raw_id = session&.id
        session_id_short = raw_id ? raw_id.to_s.slice(0, 8) : "?"
        case event
        when :session_complete
          [
            "Session complete",
            "Homunculus finished your session (#{session_id_short}). " \
            "#{session&.turn_count || 0} turns, " \
            "#{(session&.total_input_tokens || 0) + (session&.total_output_tokens || 0)} total tokens.",
            :normal
          ]
        when :confirmation_needed
          [
            "Confirmation needed",
            "Homunculus is waiting for your approval to run: #{tool_name || "unknown tool"}",
            :high
          ]
        when :error
          [
            "Agent error",
            "Homunculus encountered an error: #{detail || "unknown error"} (session #{session_id_short})",
            :high
          ]
        else
          ["Homunculus", event.to_s, :normal]
        end
      end
    end

    # Result type for the agent loop.
    # Optional tier/model/escalated_from are set when using models_router (from Models::Response).
    # context_window reflects the active model's maximum context size in tokens.
    AgentResult = Data.define(:status, :response, :error, :pending_tool_call, :session, :tier, :model,
                              :escalated_from, :context_window) do
      def self.completed(response, session:, tier: nil, model: nil, escalated_from: nil, context_window: nil)
        new(
          status: :completed, response:, error: nil, pending_tool_call: nil, session:,
          tier:, model:, escalated_from:, context_window:
        )
      end

      def self.pending_confirmation(tool_call, session:, context_window: nil)
        new(
          status: :pending_confirmation, response: nil, error: nil, pending_tool_call: tool_call, session:,
          tier: nil, model: nil, escalated_from: nil, context_window:
        )
      end

      def self.error(error, session:)
        new(
          status: :error, response: nil, error:, pending_tool_call: nil, session:,
          tier: nil, model: nil, escalated_from: nil, context_window: nil
        )
      end

      def completed? = status == :completed
      def pending? = status == :pending_confirmation
      def error? = status == :error
    end
  end
end
