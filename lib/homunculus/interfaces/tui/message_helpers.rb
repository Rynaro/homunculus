# frozen_string_literal: true

module Homunculus
  module Interfaces
    class TUI
      # Extracted message-handling, warmup, and session-summary concerns.
      module MessageHelpers
        # ── Warmup ────────────────────────────────────────────────

        def start_warmup!
          return if @warmup.nil? || !@config.agent.warmup.enabled

          @warmup.start!(callback: method(:warmup_display))
        end

        def warmup_display(event, step, detail)
          case event
          when :start then push_info_message("⏳ #{warmup_step_label(step)}...")
          when :complete then push_info_message("✓ #{warmup_step_label(step)} (#{detail[:elapsed_ms]}ms)")
          when :fail    then push_info_message("⚠ #{warmup_step_label(step)} unavailable")
          when :done    then push_info_message("✓ Ready in #{detail[:elapsed_ms]}ms")
          end
          refresh_all
        rescue StandardError => e
          logger.debug("Warmup display callback error", error: e.message)
        end

        def warmup_step_label(step)
          case step
          when :preload_chat_model      then "Loading chat model"
          when :preload_embedding_model then "Loading embedding model"
          when :preread_workspace_files then "Pre-reading workspace"
          else step.to_s.tr("_", " ").capitalize
          end
        end

        def warm_greeting_text
          hour = Time.now.hour
          greeting = if hour >= 5 && hour < 12
                       "Good morning! Ready to help with whatever you need today."
                     elsif hour >= 12 && hour < 17
                       "Good afternoon! What are we working on?"
                     elsif hour >= 17 && hour < 22
                       "Good evening! How can I help?"
                     else
                       "Burning the midnight oil? I'm here when you need me."
                     end
          "#{greeting} Type /help for commands, or just start chatting."
        end

        def session_context_line
          tier = if @current_tier && @current_model
                   "#{@current_tier} (#{@current_model})"
                 else
                   (use_models_router? ? "router" : @provider_name.to_s)
                 end
          "Session started · model: #{tier} · /help for commands"
        end

        # ── Help & Status Overlays ────────────────────────────────

        def show_help
          help_text = <<~HELP.strip
            Here's what I can do:
              help       — This message
              status     — Session and config details
              confirm    — Approve a pending tool call
              deny       — Reject a pending tool call
              clear      — Clear the chat history display
              quit / :q  — Exit
            Scroll:
              Arrow Up/Down or Page Up/Down to scroll history
            Just type naturally — I understand plain language too.
          HELP
          @messages_mutex.synchronize { @overlay_content = help_text.split("\n") }
          refresh_all
        end

        def show_status
          pending = @session.pending_tool_call&.name || "none"
          mc      = use_models_router? ? nil : resolve_model_config
          model   = mc ? (mc.default_model || mc.model) : "router"
          status_text = <<~STATUS.strip
            Session:  #{@session.id}
            Turns:    #{@session.turn_count} / #{@config.agent.max_turns}
            Tokens:   #{@session.total_input_tokens}↓  #{@session.total_output_tokens}↑
            Duration: #{@session.duration.round(1)}s
            Pending:  #{pending}
            Model:    #{model}
            Provider: #{@provider_name}
            Workspace:#{@config.agent.workspace_path}
          STATUS
          @messages_mutex.synchronize { @overlay_content = status_text.split("\n") }
          refresh_all
        end

        def show_model
          tier_label = model_tier_label.sub(/\Amodel: /, "")
          mc = use_models_router? ? nil : resolve_model_config
          model_name = mc ? (mc.default_model || mc.model) : "router"
          lines = [
            "Model tier: #{tier_label}",
            "Model:      #{model_name}",
            "Provider:   #{@provider_name}"
          ]
          tier_descs = load_tier_descriptions_from_models_toml
          if tier_descs.any?
            lines << ""
            lines.concat(tier_descs)
          end
          @messages_mutex.synchronize { @overlay_content = lines }
          refresh_all
        end

        # ── Shutdown ──────────────────────────────────────────────

        def format_int(n)
          n.to_s.gsub(/(\d)(?=(\d{3})+(?!\d))/, '\\1,')
        end

        def print_session_summary
          return unless @session && @session_start_time

          elapsed = (Time.now - @session_start_time).to_i
          duration_str = if elapsed >= 3600
                           "#{elapsed / 3600}h #{(elapsed % 3600) / 60}m"
                         else
                           "#{elapsed / 60}m #{elapsed % 60}s"
                         end
          turns     = "#{@session.turn_count}/#{@config.agent.max_turns}"
          token_str = "#{format_int(@session.total_input_tokens)}↓ #{format_int(@session.total_output_tokens)}↑"
          tool_count = @messages_mutex.synchronize { @messages.count { |m| m[:role] == :tool_request } }
          memory_line = @memory_store && @session.turn_count.positive? ? "Memory saved. " : ""
          lines = [
            "Session complete.",
            "Duration: #{duration_str} · Turns: #{turns} · Tokens: #{token_str}",
            (tool_count.positive? ? "Tools used: #{tool_count}. " : "") + "#{memory_line}See you next time!"
          ]
          $stdout.puts
          $stdout.puts(lines.join("\n"))
          $stdout.flush
        end

        def shutdown
          @activity_indicator&.stop
          @scheduler_manager&.stop
          return unless @session

          @audit.log(
            action: "session_end",
            session_id: @session.id,
            **@session.summary.except(:id)
          )
          return unless @memory_store && @session.turn_count.positive?

          @memory_store.save_transcript(@session)
        rescue StandardError => e
          logger.warn("Shutdown error", error: e.message)
        end
      end
    end
  end
end
