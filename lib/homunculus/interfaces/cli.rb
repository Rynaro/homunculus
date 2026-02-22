# frozen_string_literal: true

require "sequel"
require "fileutils"

module Homunculus
  module Interfaces
    class CLI
      include SemanticLogger::Loggable

      BANNER = <<~BANNER
        🧪 Homunculus v%<version>s — Personal AI Agent
        Model: %<model>s (%<provider>s)
        Type 'quit' to exit, 'confirm' to approve pending actions, 'help' for commands.
      BANNER

      def initialize(config:, provider_name: nil, model_override: nil)
        @config = config
        @provider_name = provider_name || "local"
        @model_override = model_override
        @running = false
        @session = nil
        @agent_loop = nil

        setup_components!
      end

      def start
        @running = true
        @session = Session.new

        print_banner
        setup_signal_handlers
        @scheduler_manager&.start

        loop_input
      ensure
        shutdown
      end

      private

      def setup_components!
        @audit = Security::AuditLogger.new(@config.security.audit_log_path)
        @memory_store = build_memory_store
        @tool_registry = build_tool_registry
        @prompt_builder = Agent::PromptBuilder.new(
          workspace_path: @config.agent.workspace_path,
          tool_registry: @tool_registry,
          memory: @memory_store
        )

        if use_models_router?
          @agent_loop = build_loop_with_models_router
        else
          model_config = resolve_model_config
          @provider = Agent::ModelProvider.new(model_config)
          @agent_loop = Agent::Loop.new(
            config: @config,
            provider: @provider,
            tools: @tool_registry,
            prompt_builder: @prompt_builder,
            audit: @audit
          )
        end

        setup_scheduler! if @config.scheduler.enabled
      end

      def use_models_router?
        File.file?(models_toml_path)
      end

      def models_toml_path
        @models_toml_path ||= File.expand_path("config/models.toml", Dir.pwd)
      end

      def build_loop_with_models_router
        models_toml = TomlRB.load_file(models_toml_path)
        ollama_config = (models_toml.dig("providers", "ollama") || {}).dup
        ollama_config["base_url"] = @config.models[:local]&.base_url || ollama_config["base_url"] || "http://127.0.0.1:11434"
        ollama_config["timeout_seconds"] =
          @config.models[:local]&.timeout_seconds || ollama_config["timeout_seconds"] || models_toml.dig("defaults",
                                                                                                         "timeout_seconds") || 120
        ollama_provider = Agent::Models::OllamaProvider.new(config: ollama_config)
        # Use default model from default.toml for workhorse tier so CLI matches banner
        default_model = @config.models[:local]&.default_model || @config.models[:local]&.model
        if default_model
          models_toml["tiers"] ||= {}
          models_toml["tiers"]["workhorse"] ||= {}
          models_toml["tiers"]["workhorse"] = models_toml["tiers"]["workhorse"].merge("model" => default_model)
        end
        models_router = Agent::Models::Router.new(config: models_toml, providers: { ollama: ollama_provider })
        stream_callback = lambda { |chunk|
          if @streaming_first_chunk
            print "\n#{colorize("Homunculus:", :green)} "
            @streaming_first_chunk = false
          end
          print chunk
        }
        Agent::Loop.new(
          config: @config,
          models_router: models_router,
          stream_callback: stream_callback,
          tools: @tool_registry,
          prompt_builder: @prompt_builder,
          audit: @audit
        )
      end

      def resolve_model_config
        key = @provider_name.to_sym
        model_config = @config.models[key]
        unless model_config
          raise ArgumentError,
                "Unknown provider: #{@provider_name}. Available: #{@config.models.keys.join(", ")}"
        end

        if @model_override
          # Create a new config with the overridden model
          attrs = model_config.attributes.merge(default_model: @model_override, model: @model_override)
          ModelConfig.new(attrs)
        else
          model_config
        end
      end

      def build_tool_registry
        registry = Tools::Registry.new

        # Register all starter tools
        registry.register(Tools::Echo.new)
        registry.register(Tools::DatetimeNow.new)
        registry.register(Tools::WorkspaceRead.new)
        registry.register(Tools::WorkspaceWrite.new)
        registry.register(Tools::WorkspaceList.new)

        # Register extended tools
        registry.register(Tools::ShellExec.new(config: @config))
        registry.register(Tools::WebFetch.new(config: @config))
        registry.register(Tools::WebExtract.new(config: @config))
        registry.register(Tools::MQTTPublish.new(config: @config))
        registry.register(Tools::MQTTSubscribe.new(config: @config))

        # Register memory tools
        if @memory_store
          registry.register(Tools::MemorySearch.new(memory_store: @memory_store))
          registry.register(Tools::MemorySave.new(memory_store: @memory_store))
          registry.register(Tools::MemoryDailyLog.new(memory_store: @memory_store))
        end

        registry
      end

      def build_memory_store
        db_path = @config.memory.db_path
        FileUtils.mkdir_p(File.dirname(db_path))
        db = Sequel.sqlite(db_path)

        # Build embedder if configured
        embedder = nil
        local_model_config = @config.models[:local]
        if local_model_config&.base_url
          embedder = Memory::Embedder.new(
            base_url: local_model_config.base_url,
            model: @config.memory.embedding_model
          )
        end

        store = Memory::Store.new(config: @config, db:, embedder:)

        # Ensure index is built on first run
        store.rebuild_index! if db[:memory_chunks].none?

        store
      rescue StandardError => e
        logger.warn("Memory store initialization failed, running without memory", error: e.message)
        nil
      end

      def print_banner
        model_config = resolve_model_config
        model_name = model_config.default_model || model_config.model
        provider = model_config.provider.capitalize

        puts format(BANNER, version: VERSION, model: model_name, provider:)
        puts "-" * 60
      end

      def setup_signal_handlers
        trap("INT") do
          puts "\n\n⚡ Interrupted. Saving session..."
          @running = false
        end
      end

      def loop_input
        while @running
          print "\n#{colorize("You: ", :cyan)}"
          input = $stdin.gets&.chomp

          break if input.nil? # EOF

          input = input.scrub

          case input.strip.downcase
          when "exit", "quit"
            break
          when "help"
            print_help
          when "status"
            print_status
          when "scheduler"
            print_scheduler_status
          when "confirm"
            handle_confirm
          when "deny"
            handle_deny
          when ""
            next
          else
            handle_message(input)
          end
        end
      end

      def handle_message(message)
        if @session.pending_tool_call
          puts colorize("⚠️  There's a pending tool call. Type 'confirm' or 'deny' first.", :yellow)
          return
        end

        logger.info("CLI input", length: message.length, session_id: @session.id)

        @streaming_first_chunk = true if use_models_router?
        result = @agent_loop.run(message, @session)
        display_result(result)
      rescue StandardError => e
        logger.error("Error processing message", error: e.message, backtrace: e.backtrace&.first(5))
        puts colorize("\n❌ Error: #{e.message}", :red)
      end

      def handle_confirm
        unless @session.pending_tool_call
          puts colorize("No pending action to confirm.", :yellow)
          return
        end

        puts colorize("✅ Confirmed.", :green)
        result = @agent_loop.confirm_tool(@session)
        display_result(result)
      rescue StandardError => e
        logger.error("Error confirming tool", error: e.message)
        puts colorize("\n❌ Error: #{e.message}", :red)
      end

      def handle_deny
        unless @session.pending_tool_call
          puts colorize("No pending action to deny.", :yellow)
          return
        end

        puts colorize("🚫 Denied.", :red)
        result = @agent_loop.deny_tool(@session)
        display_result(result)
      rescue StandardError => e
        logger.error("Error denying tool", error: e.message)
        puts colorize("\n❌ Error: #{e.message}", :red)
      end

      def display_result(result)
        case result.status
        when :completed
          puts "\n#{colorize("Homunculus:", :green)} #{result.response}" unless use_models_router?

        when :pending_confirmation
          tc = result.pending_tool_call
          puts colorize("\n⚠️  This action requires confirmation:", :yellow)
          puts "  Tool: #{colorize(tc.name, :cyan)}"
          puts "  Arguments: #{tc.arguments.inspect}"
          puts colorize("  Type 'confirm' to proceed or 'deny' to cancel.", :yellow)

        when :error
          puts colorize("\n❌ #{result.error}", :red)
        end

        # Show usage summary
        return unless @session.total_input_tokens.positive? || @session.total_output_tokens.positive?

        puts "" if use_models_router? && result.status == :completed
        puts colorize(
          "  [tokens: #{@session.total_input_tokens}↓ #{@session.total_output_tokens}↑ | " \
          "turns: #{@session.turn_count}]",
          :dim
        )
      end

      def print_help
        puts <<~HELP

          #{colorize("Commands:", :cyan)}
            help      — Show this help message
            status    — Show session status
            scheduler — Show scheduler and heartbeat status
            confirm   — Approve a pending tool action
            deny      — Reject a pending tool action
            quit/exit — Exit the CLI

          #{colorize("Flags (at startup):", :cyan)}
            --model MODEL      Override the default model
            --provider NAME    Switch provider (ollama/anthropic)

          #{colorize("Available tools:", :cyan)}
        HELP

        @tool_registry.tool_names.each do |name|
          tool = @tool_registry[name]
          confirm = tool.requires_confirmation ? " ⚠️" : ""
          puts "    #{colorize(name, :green)}#{confirm} — #{tool.description}"
        end
      end

      def print_status
        puts <<~STATUS

          #{colorize("Session Status:", :cyan)}
            Session ID:    #{@session.id}
            Status:        #{@session.status}
            Turns:         #{@session.turn_count}
            Messages:      #{@session.messages.size}
            Input tokens:  #{@session.total_input_tokens}
            Output tokens: #{@session.total_output_tokens}
            Duration:      #{@session.duration.round(1)}s
            Pending:       #{@session.pending_tool_call ? @session.pending_tool_call.name : "none"}

          #{colorize("Configuration:", :cyan)}
            Provider:      #{@provider_name}
            Model:         #{resolve_model_config.default_model || resolve_model_config.model}
            Workspace:     #{@config.agent.workspace_path}
            Max turns:     #{@config.agent.max_turns}
            Tools:         #{@tool_registry.size} registered
        STATUS
      end

      def shutdown
        @scheduler_manager&.stop

        return unless @session

        @audit.log(
          action: "session_end",
          session_id: @session.id,
          **@session.summary.except(:id)
        )

        # Auto-summary and transcript save
        if @memory_store && @session.turn_count.positive?
          auto_summarize_session
          @memory_store.save_transcript(@session)
        end

        puts "\n#{colorize("Session summary:", :dim)}"
        puts colorize(
          "  #{@session.turn_count} turns, " \
          "#{@session.total_input_tokens + @session.total_output_tokens} total tokens, " \
          "#{@session.duration.round(1)}s",
          :dim
        )
        puts "Homunculus shutting down. Goodbye. 👋"
      end

      def auto_summarize_session
        return unless @session.turn_count.positive?
        return unless @provider

        # Build a summary request using the same provider
        summary_messages = [
          { role: "user", content: format_conversation_for_summary },
          { role: "user", content: Memory::Store.summary_prompt }
        ]

        response = @provider.complete(
          messages: summary_messages,
          system: "You are a concise summarizer. Extract key facts from conversations.",
          max_tokens: 1024,
          temperature: 0.3
        )

        summary = response.content&.scrub&.strip
        return if summary.nil? || summary.empty? || summary == "NO_SUMMARY"

        @memory_store.save_conversation_summary(
          session_id: @session.id,
          summary:
        )
        puts colorize("  📝 Session summarized to memory.", :dim)
      rescue StandardError => e
        logger.warn("Auto-summary failed", error: e.message)
      end

      def format_conversation_for_summary
        @session.messages.map do |msg|
          role = msg[:role].to_s.capitalize
          "#{role}: #{msg[:content]}"
        end.join("\n\n")
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

        service.deliver_fn = lambda { |text, _priority|
          $stdout.puts "\n#{colorize("─" * 60, :magenta)}"
          $stdout.puts "#{colorize("🔔 Scheduler:", :magenta)} #{text}"
          $stdout.puts colorize("─" * 60, :magenta)
          $stdout.print "\n#{colorize("You: ", :cyan)}"
          $stdout.flush
        }

        service
      end

      def print_scheduler_status
        unless @scheduler_manager
          puts colorize("Scheduler is not running.", :yellow)
          return
        end

        status = @scheduler_manager.status
        hb_config = @config.scheduler.heartbeat
        jobs = @scheduler_manager.list_jobs

        puts <<~STATUS

          #{colorize("Scheduler Status:", :cyan)}
            Running:       #{status[:running] ? colorize("yes", :green) : colorize("no", :red)}
            Active hours:  #{hb_config.active_hours_start}:00–#{hb_config.active_hours_end}:00 (#{hb_config.timezone})
            Currently:     #{status[:active_hours] ? colorize("active", :green) : colorize("quiet hours", :yellow)}
            Queued:        #{status[:queue_size]} notification(s)

          #{colorize("Jobs (#{jobs.size}):", :cyan)}
        STATUS

        if jobs.empty?
          puts "    (none)"
        else
          jobs.each do |job|
            state = job[:paused] ? colorize("paused", :yellow) : colorize("active", :green)
            next_run = job[:next_time] || "N/A"
            puts "    #{colorize(job[:name], :green)} [#{job[:type]}] #{state} — next: #{next_run}"
          end
        end

        puts "\n  #{colorize("Recent heartbeat executions:", :cyan)}"
        executions = @scheduler_manager.recent_executions("heartbeat", limit: 5)
        if executions.empty?
          puts "    (none yet)"
        else
          executions.each do |exec|
            time = exec[:executed_at]&.strftime("%Y-%m-%d %H:%M") || "?"
            puts "    #{time} — #{exec[:status]} (#{exec[:duration_ms]}ms)"
          end
        end
      end

      # Simple ANSI color support (no external gem dependency)
      def colorize(text, color)
        codes = {
          red: 31, green: 32, yellow: 33, blue: 34,
          magenta: 35, cyan: 36, white: 37, dim: 2
        }
        code = codes.fetch(color, 0)
        "\e[#{code}m#{text}\e[0m"
      end
    end
  end
end
