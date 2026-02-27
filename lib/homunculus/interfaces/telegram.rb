# frozen_string_literal: true

require "sequel"
require "fileutils"
require "telegram/bot"
require_relative "telegram/memory_curation"

module Homunculus
  module Interfaces
    class Telegram
      include SemanticLogger::Loggable
      include MemoryCuration

      # Per-chat session entry
      SessionEntry = Struct.new(:session, :last_activity, keyword_init: true)

      def initialize(config:, provider_name: nil)
        @config = config
        @provider_name = provider_name || "local"
        @sessions = {} # chat_id => SessionEntry
        @running = false

        telegram_config = config.telegram
        raise ArgumentError, "Telegram bot token is required (set TELEGRAM_BOT_TOKEN)" unless telegram_config.bot_token

        @allowed_users = Set.new(telegram_config.allowed_user_ids)
        @session_timeout = telegram_config.session_timeout_minutes * 60
        @max_message_length = telegram_config.max_message_length
        @typing_indicator = telegram_config.typing_indicator

        setup_components!
        @bot = ::Telegram::Bot::Client.new(telegram_config.bot_token)
        setup_scheduler! if config.scheduler.enabled
      end

      def start
        @running = true
        logger.info("Telegram bot starting",
                    allowed_users: @allowed_users.size,
                    default_provider: @provider_name,
                    routing: "automatic",
                    escalation: @config.escalation_enabled? ? "enabled" : "disabled (local-only)")

        @scheduler_manager&.start

        @bot.listen do |update|
          handle_update(update)
        rescue StandardError => e
          logger.error("Error handling update", error: e.message, backtrace: e.backtrace&.first(5))
        end
      ensure
        shutdown
      end

      private

      # ── Component Setup ──────────────────────────────────────────────

      def setup_components!
        @audit = Security::AuditLogger.new(@config.security.audit_log_path)
        @memory_store = build_memory_store
        @tool_registry = build_tool_registry

        # Multi-agent manager (loads workspace/agents/)
        workspace_path = @config.agent.workspace_path
        @agent_manager = Agent::MultiAgentManager.new(
          workspace_path: workspace_path,
          config: @config
        )

        # Skill loader (loads workspace/skills/)
        skills_dir = File.join(workspace_path, "skills")
        @skill_loader = Skills::Loader.new(skills_dir: skills_dir)

        @prompt_builder = Agent::PromptBuilder.new(
          workspace_path: workspace_path,
          tool_registry: @tool_registry,
          memory: @memory_store,
          skill_loader: @skill_loader,
          agent_manager: @agent_manager
        )

        # Build model providers
        @providers = {}
        @providers[:ollama] = Agent::ModelProvider.new(@config.models[:local]) if @config.models[:local]
        if @config.escalation_enabled? && @config.models[:escalation]
          @providers[:anthropic] = Agent::ModelProvider.new(@config.models[:escalation])
        end
        providers = @providers

        # Budget tracker (uses data/ directory alongside other DBs)
        budget_limit = @config.models[:escalation]&.daily_budget_usd || 2.0
        @budget = Agent::BudgetTracker.new(
          daily_limit_usd: budget_limit,
          db: open_budget_db
        )

        # Intelligent model router
        @router = Agent::Router.new(config: @config, budget: @budget)

        # Single routing-aware agent loop
        @agent_loop = Agent::Loop.new(
          config: @config,
          providers:,
          router: @router,
          tools: @tool_registry,
          prompt_builder: @prompt_builder,
          audit: @audit
        )

        # Start agent Ractors
        @agent_manager.start_agents!
      end

      def setup_scheduler!
        @scheduler_manager = Scheduler::Manager.new(
          config: @config,
          agent_loop: @agent_loop,
          notification: build_notification_service,
          job_store: Scheduler::JobStore.new(db_path: @config.scheduler.db_path)
        )

        @tool_registry.register(Tools::SchedulerManage.new(scheduler_manager: @scheduler_manager))

        @heartbeat = Scheduler::Heartbeat.new(
          config: @config,
          scheduler_manager: @scheduler_manager
        )
        @heartbeat.setup!

        logger.info("Scheduler initialized",
                    heartbeat_enabled: @config.scheduler.heartbeat.enabled,
                    persisted_jobs: @scheduler_manager.list_jobs.size)
      rescue StandardError => e
        logger.error("Scheduler setup failed", error: e.message, backtrace: e.backtrace&.first(5))
        @scheduler_manager = nil
      end

      def build_notification_service
        service = Scheduler::Notification.new(config: @config)

        # Wire up the Telegram delivery function: sends to all allowed users
        service.deliver_fn = lambda { |text, priority|
          delivery_targets.each do |chat_id|
            prefix = priority == :high ? "🚨 *HIGH PRIORITY*\n\n" : "🔔 "
            send_long_message(chat_id, "#{prefix}#{text}")
          end
        }

        service
      end

      # Chat IDs to deliver scheduled notifications to.
      # Uses the allowed_user_ids as the notification targets.
      def delivery_targets
        @allowed_users.to_a
      end

      def build_tool_registry
        registry = Tools::Registry.new

        registry.register(Tools::Echo.new)
        registry.register(Tools::DatetimeNow.new)
        registry.register(Tools::WorkspaceRead.new)
        registry.register(Tools::WorkspaceWrite.new)
        registry.register(Tools::WorkspaceList.new)

        # Register extended tools
        registry.register(Tools::ShellExec.new(config: @config))
        registry.register(Tools::WebFetch.new(config: @config))
        registry.register(Tools::MQTTPublish.new(config: @config))
        registry.register(Tools::MQTTSubscribe.new(config: @config))

        if @memory_store
          registry.register(Tools::MemorySearch.new(memory_store: @memory_store))
          registry.register(Tools::MemorySave.new(memory_store: @memory_store))
          registry.register(Tools::MemoryDailyLog.new(memory_store: @memory_store))
          registry.register(Tools::MemoryCurate.new(memory_store: @memory_store))
        end

        registry
      end

      def build_memory_store
        db_path = @config.memory.db_path
        FileUtils.mkdir_p(File.dirname(db_path))
        db = Sequel.sqlite(db_path)

        embedder = nil
        local_model_config = @config.models[:local]
        if local_model_config&.base_url
          embedder = Memory::Embedder.new(
            base_url: local_model_config.base_url,
            model: @config.memory.embedding_model
          )
        end

        store = Memory::Store.new(config: @config, db:, embedder:)
        store.rebuild_index! if db[:memory_chunks].none?
        store
      rescue StandardError => e
        logger.warn("Memory store initialization failed, running without memory", error: e.message)
        nil
      end

      def open_budget_db
        db_dir = File.dirname(@config.scheduler.db_path)
        FileUtils.mkdir_p(db_dir)
        Sequel.sqlite(File.join(db_dir, "budget.db"))
      end

      # ── Update Routing ──────────────────────────────────────────────

      def handle_update(update)
        case update
        when ::Telegram::Bot::Types::Message
          handle_message(update)
        when ::Telegram::Bot::Types::CallbackQuery
          handle_callback(update)
        end
      end

      def handle_message(message)
        chat_id = message.chat.id
        user_id = message.from&.id

        unless authorized?(user_id)
          logger.info("Unauthorized access attempt", user_id:, chat_id:)
          return # Silent rejection
        end

        text = message.text&.strip
        return if text.nil? || text.empty?

        chat_type = message.chat.type || "private"

        if text.start_with?("/")
          handle_command(chat_id, text, chat_type:)
        else
          handle_chat(chat_id, text, chat_type:)
        end
      end

      def handle_callback(callback)
        chat_id = callback.message.chat.id
        user_id = callback.from&.id

        unless authorized?(user_id)
          logger.info("Unauthorized callback attempt", user_id:, chat_id:)
          return
        end

        data = callback.data
        case data
        when "confirm"
          handle_confirm(chat_id, callback.id)
        when "deny"
          handle_deny(chat_id, callback.id)
        else
          answer_callback(callback.id, "Unknown action")
        end
      end

      # ── Authorization ───────────────────────────────────────────────

      def authorized?(user_id)
        return false if user_id.nil?
        return true if @allowed_users.empty? # No whitelist configured (dev mode)
        return true if @allowed_users.include?(user_id)

        @audit.log(action: "unauthorized_access", user_id:)
        false
      end

      # ── Commands ────────────────────────────────────────────────────

      def handle_command(chat_id, text, chat_type: "private")
        command, *args = text.split(/\s+/)

        case command.downcase
        when "/start"
          cmd_start(chat_id)
        when "/new"
          cmd_new_session(chat_id, chat_type:)
        when "/memory"
          cmd_memory(chat_id, args.join(" "))
        when "/status"
          cmd_status(chat_id)
        when "/escalate"
          cmd_escalate(chat_id)
        when "/local"
          cmd_local(chat_id)
        when "/auto"
          cmd_auto(chat_id)
        when "/budget"
          cmd_budget(chat_id)
        when "/scheduler"
          cmd_scheduler(chat_id)
        when "/agents"
          cmd_agents(chat_id)
        when "/skills"
          cmd_skills(chat_id)
        when "/enable"
          cmd_enable_skill(chat_id, args.first)
        when "/disable"
          cmd_disable_skill(chat_id, args.first)
        else
          send_message(chat_id, "Unknown command: #{command}\nType /start to see available commands.")
        end
      end

      def cmd_start(chat_id)
        model_config = @config.models[:local]
        model_name = model_config&.default_model || model_config&.model || "unknown"

        agent_count = @agent_manager.size
        skill_count = @skill_loader.size

        send_message(chat_id, <<~MSG.strip)
          🧪 *Homunculus v#{VERSION}*
          Personal AI Agent — Telegram Interface

          *Local model:* `#{model_name}`
          *Routing:* automatic
          *Agents:* #{agent_count} loaded
          *Skills:* #{skill_count} loaded

          *Commands:*
          /new — Start a fresh session
          /memory <query> — Search memory
          /status — Session info & token usage
          /escalate — Force Claude for this session
          /local — Force local model
          /auto — Return to automatic routing
          /budget — Show today's usage & remaining budget
          /scheduler — Scheduler & heartbeat status
          /agents — List available agents
          /skills — List available skills
          /enable <skill> — Enable a skill
          /disable <skill> — Disable a skill

          *Agent routing:* Use @agent\\_name to route to a specific agent.
          Example: `@coder fix this bug`

          Send any message to start chatting.
        MSG
      end

      def cmd_new_session(chat_id, chat_type: "private")
        entry = @sessions.delete(chat_id)

        if entry
          save_session_summary(entry.session)
          @audit.log(action: "session_end", session_id: entry.session.id, **entry.session.summary.except(:id))
        end

        session = Session.new
        session.source = chat_type_to_source(chat_type)
        @sessions[chat_id] = SessionEntry.new(session:, last_activity: Time.now)

        send_message(chat_id, "🆕 New session started.\nSession ID: `#{session.id}`")
      end

      def cmd_memory(chat_id, query)
        if query.empty?
          send_message(chat_id, "Usage: /memory <search query>")
          return
        end

        unless @memory_store
          send_message(chat_id, "⚠️ Memory system is not available.")
          return
        end

        results = @memory_store.search(query, limit: 5)

        if results.empty?
          send_message(chat_id, "No results found for: _#{escape_markdown(query)}_")
          return
        end

        response = results.map.with_index(1) do |r, i|
          source = r[:source] || "unknown"
          snippet = truncate(r[:content], 200)
          "#{i}. *#{escape_markdown(source)}*\n#{escape_markdown(snippet)}"
        end.join("\n\n")

        send_message(chat_id, "🔍 *Memory search:* _#{escape_markdown(query)}_\n\n#{response}")
      end

      def cmd_status(chat_id)
        entry = @sessions[chat_id]
        session = entry&.session

        routing_mode = if session&.forced_provider
                         session.forced_provider.to_s
                       else
                         "auto"
                       end

        model_config = @config.models[:local]
        model_name = model_config&.default_model || model_config&.model || "unknown"

        if session
          active_agent = session.active_agent || :default
          enabled = session.enabled_skills.to_a
          skills_text = enabled.empty? ? "none" : enabled.join(", ")

          send_message(chat_id, <<~MSG.strip)
            📊 *Session Status*

            *Session ID:* `#{session.id}`
            *Status:* #{session.status}
            *Turns:* #{session.turn_count}
            *Messages:* #{session.messages.size}
            *Tokens:* #{session.total_input_tokens}↓ #{session.total_output_tokens}↑
            *Duration:* #{session.duration.round(1)}s
            *Pending:* #{session.pending_tool_call ? session.pending_tool_call.name : "none"}

            *Agent:* @#{active_agent}
            *Skills:* #{skills_text}
            *Routing:* #{routing_mode}
            *Local model:* `#{model_name}`
            #{budget_status_text}
          MSG
        else
          send_message(chat_id, <<~MSG.strip)
            📊 *No active session*

            *Routing:* #{routing_mode}
            *Local model:* `#{model_name}`
            #{budget_status_text}

            Send a message or /new to start a session.
          MSG
        end
      end

      def cmd_escalate(chat_id)
        unless @config.models[:escalation]
          send_message(chat_id, "⚠️ Escalation model is not configured.")
          return
        end

        unless @config.escalation_enabled?
          send_message(chat_id, "⚠️ Remote escalation is disabled. Running in local\\-only mode.\n" \
                                "Set `ESCALATION_ENABLED=true` or update config to re\\-enable.")
          return
        end

        entry = session_entry_for(chat_id)
        entry.session.forced_provider = :anthropic

        model_name = @config.models[:escalation].model
        send_message(chat_id,
                     "⬆️ Forced to *#{escape_markdown(model_name)}*\nUse /auto to return to automatic routing.")
      end

      def cmd_local(chat_id)
        entry = session_entry_for(chat_id)
        entry.session.forced_provider = :ollama

        model_config = @config.models[:local]
        model_name = model_config.default_model || model_config.model
        send_message(chat_id,
                     "⬇️ Forced to *#{escape_markdown(model_name)}*\nUse /auto to return to automatic routing.")
      end

      def cmd_auto(chat_id)
        entry = session_entry_for(chat_id)
        entry.session.forced_provider = nil

        send_message(chat_id, "🔄 Automatic model routing enabled.\nSimple tasks → local model, complex tasks → Claude.")
      end

      def cmd_budget(chat_id)
        unless @config.escalation_enabled?
          send_message(chat_id, <<~MSG.strip)
            💰 *Budget Status*

            *Escalation:* disabled \\(local\\-only mode\\)
            Claude budget tracking is inactive\\.
          MSG
          return
        end

        summary = @budget.usage_summary

        send_message(chat_id, <<~MSG.strip)
          💰 *Budget Status*

          *Daily limit:* $#{summary[:daily_limit_usd]}
          *Spent today:* $#{summary[:spent_today_usd]}
          *Remaining:* $#{summary[:remaining_usd]}
          *Claude available:* #{summary[:can_use_claude] ? "✅" : "❌"}
        MSG
      end

      def cmd_scheduler(chat_id)
        unless @scheduler_manager
          send_message(chat_id, "⚠️ Scheduler is not enabled.")
          return
        end

        status = @scheduler_manager.status
        jobs = @scheduler_manager.list_jobs

        jobs_text = if jobs.empty?
                      "_No scheduled jobs_"
                    else
                      jobs.map do |j|
                        state = j[:paused] ? "⏸" : "▶️"
                        "#{state} *#{escape_markdown(j[:name])}* (#{j[:type]})\n    " \
                          "Next: #{j[:next_time] || "N/A"}"
                      end.join("\n")
                    end

        send_message(chat_id, <<~MSG.strip)
          ⏰ *Scheduler Status*

          *Running:* #{status[:running] ? "✅" : "❌"}
          *Active hours:* #{status[:active_hours] ? "☀️ Yes" : "🌙 Quiet"}
          *Notification queue:* #{status[:queue_size]}

          *Jobs (#{status[:job_count]}):*
          #{jobs_text}
        MSG
      end

      # ── Agent & Skill Commands ────────────────────────────────────────

      def cmd_agents(chat_id)
        agents = @agent_manager.list_agents

        if agents.empty?
          send_message(chat_id, "⚠️ No agents loaded.")
          return
        end

        entry = session_entry_for(chat_id)
        active = entry.session.active_agent

        lines = agents.map do |a|
          indicator = a[:name].to_sym == active ? "▶️" : "◻️"
          model_hint = case a[:model_preference]
                       when :escalation then "☁️"
                       when :local then "🏠"
                       else "🔄"
                       end
          "#{indicator} #{model_hint} *@#{escape_markdown(a[:name])}*\n    #{escape_markdown(a[:description])}"
        end.join("\n")

        send_message(chat_id, <<~MSG.strip)
          🤖 *Available Agents*

          #{lines}

          Use `@agent_name message` to route to an agent.
          Active agent: *@#{escape_markdown(active.to_s)}*
        MSG
      end

      def cmd_skills(chat_id)
        entry = session_entry_for(chat_id)
        session = entry.session

        all_skills = @skill_loader.all

        if all_skills.empty?
          send_message(chat_id, "⚠️ No skills loaded.")
          return
        end

        lines = all_skills.map do |s|
          enabled = session.skill_enabled?(s.name) || s.auto_activate
          indicator = enabled ? "✅" : "◻️"
          auto = s.auto_activate ? " _(auto)_" : ""
          triggers = s.triggers.first(3).map { |t| "`#{escape_markdown(t)}`" }.join(", ")
          "#{indicator} *#{escape_markdown(s.name)}*#{auto}\n    " \
            "#{escape_markdown(s.description)}\n    " \
            "Triggers: #{triggers}"
        end.join("\n\n")

        send_message(chat_id, <<~MSG.strip)
          🧩 *Available Skills*

          #{lines}

          Use `/enable <skill>` or `/disable <skill>` to manage.
        MSG
      end

      def cmd_enable_skill(chat_id, skill_name)
        if skill_name.nil? || skill_name.empty?
          send_message(chat_id, "Usage: /enable <skill\\_name>\nUse /skills to see available skills.")
          return
        end

        skill = @skill_loader[skill_name]
        unless skill
          send_message(chat_id,
                       "⚠️ Unknown skill: `#{escape_markdown(skill_name)}`\nUse /skills to see available skills.")
          return
        end

        # Validate that the skill's required tools exist
        missing = @skill_loader.validate_tools(skill, @tool_registry)
        unless missing.empty?
          send_message(chat_id,
                       "⚠️ Skill `#{escape_markdown(skill_name)}` requires unavailable tools: #{missing.join(", ")}")
          return
        end

        entry = session_entry_for(chat_id)
        entry.session.enable_skill(skill_name)

        send_message(chat_id,
                     "✅ Skill *#{escape_markdown(skill.name)}* enabled.\n#{escape_markdown(skill.description)}")
      end

      def cmd_disable_skill(chat_id, skill_name)
        if skill_name.nil? || skill_name.empty?
          send_message(chat_id, "Usage: /disable <skill\\_name>\nUse /skills to see available skills.")
          return
        end

        skill = @skill_loader[skill_name]
        unless skill
          send_message(chat_id, "⚠️ Unknown skill: `#{escape_markdown(skill_name)}`")
          return
        end

        entry = session_entry_for(chat_id)
        entry.session.disable_skill(skill_name)

        send_message(chat_id, "🚫 Skill *#{escape_markdown(skill.name)}* disabled.")
      end

      # ── Chat Handling ───────────────────────────────────────────────

      def handle_chat(chat_id, text, chat_type: "private")
        entry = session_entry_for(chat_id, chat_type:)
        session = entry.session

        if session.pending_tool_call
          send_message(chat_id, "⚠️ There's a pending tool confirmation. Please respond to it first.")
          return
        end

        send_typing(chat_id)

        # Detect agent routing: @agent_name message
        detected_agent, cleaned_message = @agent_manager.detect_agent(text)

        # If agent changed, notify user and update session
        if detected_agent != session.active_agent
          old_agent = session.active_agent
          session.active_agent = detected_agent

          send_message(chat_id,
                       "🔄 Switching to *@#{escape_markdown(detected_agent.to_s)}*#{if old_agent != :default
                                                                                     " from @#{escape_markdown(old_agent.to_s)}"
                                                                                   end}...")

          logger.info("Agent switch", chat_id:, from: old_agent, to: detected_agent,
                                      session_id: session.id)
        end

        logger.info("Telegram chat", chat_id:, length: text.length, session_id: session.id,
                                     routing: session.forced_provider || "auto",
                                     agent: session.active_agent)

        result = @agent_loop.run(cleaned_message, session)
        display_result(chat_id, result)
      rescue StandardError => e
        logger.error("Error processing chat", error: e.message, chat_id:,
                                              backtrace: e.backtrace&.first(5))
        send_message(chat_id, "❌ Error: #{escape_markdown(e.message)}")
      end

      # ── Confirmation Flow ───────────────────────────────────────────

      def handle_confirm(chat_id, callback_id)
        entry = @sessions[chat_id]
        session = entry&.session

        unless session&.pending_tool_call
          answer_callback(callback_id, "No pending action to confirm.")
          return
        end

        answer_callback(callback_id, "✅ Confirmed")
        send_typing(chat_id)

        result = @agent_loop.confirm_tool(session)
        display_result(chat_id, result)
      rescue StandardError => e
        logger.error("Error confirming tool", error: e.message, chat_id:)
        send_message(chat_id, "❌ Error: #{escape_markdown(e.message)}")
      end

      def handle_deny(chat_id, callback_id)
        entry = @sessions[chat_id]
        session = entry&.session

        unless session&.pending_tool_call
          answer_callback(callback_id, "No pending action to deny.")
          return
        end

        answer_callback(callback_id, "🚫 Denied")

        result = @agent_loop.deny_tool(session)
        display_result(chat_id, result)
      rescue StandardError => e
        logger.error("Error denying tool", error: e.message, chat_id:)
        send_message(chat_id, "❌ Error: #{escape_markdown(e.message)}")
      end

      # ── Result Display ──────────────────────────────────────────────

      def display_result(chat_id, result)
        case result.status
        when :completed
          send_long_message(chat_id, result.response || "(empty response)")

        when :pending_confirmation
          tc = result.pending_tool_call
          text = <<~MSG.strip
            ⚠️ *Action requires confirmation:*

            *Tool:* `#{tc.name}`
            *Arguments:*
            ```
            #{tc.arguments.inspect}
            ```
          MSG

          keyboard = ::Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [
                ::Telegram::Bot::Types::InlineKeyboardButton.new(text: "✅ Confirm", callback_data: "confirm"),
                ::Telegram::Bot::Types::InlineKeyboardButton.new(text: "❌ Deny", callback_data: "deny")
              ]
            ]
          )

          @bot.api.send_message(
            chat_id:,
            text:,
            parse_mode: "Markdown",
            reply_markup: keyboard
          )

        when :error
          send_message(chat_id, "❌ #{escape_markdown(result.error)}")
        end

        # Show usage footer
        session = result.session
        return unless session && (session.total_input_tokens.positive? || session.total_output_tokens.positive?)

        footer = "_\\[tokens: #{session.total_input_tokens}↓ #{session.total_output_tokens}↑ " \
                 "| turns: #{session.turn_count}\\]_"
        @bot.api.send_message(chat_id:, text: footer, parse_mode: "MarkdownV2")
      end

      # ── Session Management ──────────────────────────────────────────

      def session_entry_for(chat_id, chat_type: "private")
        entry = @sessions[chat_id]

        if entry && !session_expired?(entry)
          entry.last_activity = Time.now
          return entry
        end

        # Expire old session if it exists
        if entry
          save_session_summary(entry.session)
          @audit.log(action: "session_expired", session_id: entry.session.id, chat_id:)
        end

        # Create new session (forced_provider resets to nil = auto)
        session = Session.new
        session.source = chat_type_to_source(chat_type)
        new_entry = SessionEntry.new(session:, last_activity: Time.now)
        @sessions[chat_id] = new_entry
        new_entry
      end

      def session_expired?(entry)
        (Time.now - entry.last_activity) > @session_timeout
      end

      def cleanup_expired_sessions!
        @sessions.each do |chat_id, entry|
          next unless session_expired?(entry)

          save_session_summary(entry.session)
          @audit.log(action: "session_expired", session_id: entry.session.id, chat_id:)
          @sessions.delete(chat_id)
        end
      end

      # ── Message Helpers ─────────────────────────────────────────────

      def send_message(chat_id, text)
        @bot.api.send_message(chat_id:, text:, parse_mode: "Markdown")
      rescue ::Telegram::Bot::Exceptions::ResponseError => e
        # Retry without markdown if parsing fails
        logger.warn("Markdown parse failed, retrying plain", error: e.message)
        @bot.api.send_message(chat_id:, text:)
      end

      def send_long_message(chat_id, text)
        split_message(text).each do |chunk|
          @bot.api.send_message(chat_id:, text: chunk)
        end
      end

      def send_typing(chat_id)
        return unless @typing_indicator

        @bot.api.send_chat_action(chat_id:, action: "typing")
      rescue StandardError
        # Non-critical, ignore
      end

      def answer_callback(callback_id, text)
        @bot.api.answer_callback_query(callback_query_id: callback_id, text:)
      rescue StandardError => e
        logger.warn("Failed to answer callback", error: e.message)
      end

      def split_message(text)
        return [text] if text.length <= @max_message_length

        chunks = []
        remaining = text

        while remaining.length > @max_message_length
          # Try to split at paragraph boundary
          split_at = remaining.rindex("\n\n", @max_message_length)
          # Fall back to newline
          split_at = remaining.rindex("\n", @max_message_length) if split_at.nil? || split_at < @max_message_length / 2
          # Fall back to space
          split_at = remaining.rindex(" ", @max_message_length) if split_at.nil? || split_at < @max_message_length / 2
          # Last resort: hard split
          split_at = @max_message_length if split_at.nil? || split_at < @max_message_length / 2

          chunks << remaining[0...split_at]
          remaining = remaining[split_at..].lstrip
        end

        chunks << remaining unless remaining.empty?
        chunks
      end

      # ── Helpers ─────────────────────────────────────────────────────

      def budget_status_text
        return "*Escalation:* disabled (local-only mode)" unless @config.escalation_enabled?

        summary = @budget.usage_summary
        "*Budget:* $#{summary[:spent_today_usd]}/$#{summary[:daily_limit_usd]} " \
          "(#{summary[:can_use_claude] ? "✅ Claude available" : "❌ Claude exhausted"})"
      end

      def escape_markdown(text)
        return "" if text.nil?

        text.to_s.gsub(/([_*\[\]()~`>#+\-=|{}.!])/, '\\\\\1')
      end

      def truncate(text, max_length)
        return text if text.length <= max_length

        "#{text[0...(max_length - 3)]}..."
      end

      def save_session_summary(session)
        return unless @memory_store && session.turn_count.positive?

        @memory_store.save_transcript(session)
        auto_curate_memory(session)
      rescue StandardError => e
        logger.warn("Failed to save session transcript", error: e.message, session_id: session.id)
      end

      def shutdown
        logger.info("Telegram bot shutting down")

        @scheduler_manager&.stop
        @agent_manager&.stop!

        @sessions.each_value do |entry|
          save_session_summary(entry.session)
          @audit.log(action: "session_end", session_id: entry.session.id,
                     **entry.session.summary.except(:id, :enabled_skills))
        end
        @sessions.clear
      end
    end
  end
end
