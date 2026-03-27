# frozen_string_literal: true

module Homunculus
  module Interfaces
    class TUI
      # Extracted setup/bootstrap concerns — keeps main class under 700 lines.
      module SetupHelpers
        def use_models_router?
          File.file?(models_toml_path)
        end

        def models_toml_path
          @models_toml_path ||= File.expand_path("config/models.toml", Dir.pwd)
        end

        def build_models_router_infrastructure!
          models_toml   = TomlRB.load_file(models_toml_path)
          ollama_config = build_ollama_config(models_toml)
          @ollama_provider = Agent::Models::OllamaProvider.new(config: ollama_config)
          default_model    = @config.models[:local]&.default_model || @config.models[:local]&.model
          @models_toml_data = apply_default_model(models_toml, default_model)
          @models_router = Agent::Models::Router.new(
            config: @models_toml_data,
            providers: { ollama: @ollama_provider }
          )
        end

        def build_ollama_config(models_toml)
          cfg = (models_toml.dig("providers", "ollama") || {}).dup
          cfg["base_url"] =
            @config.models[:local]&.base_url || cfg["base_url"] || "http://127.0.0.1:11434"
          cfg["timeout_seconds"] =
            @config.models[:local]&.timeout_seconds ||
            cfg["timeout_seconds"] ||
            models_toml.dig("defaults", "timeout_seconds") || 120
          cfg
        end

        def apply_default_model(models_toml, default_model)
          data = models_toml
          if default_model
            data["tiers"] ||= {}
            data["tiers"]["workhorse"] ||= {}
            data["tiers"]["workhorse"] = data["tiers"]["workhorse"].merge("model" => default_model)
          end
          data
        end

        def build_loop_with_models_router(status_callback: nil)
          stream_cb = build_stream_callback
          Agent::Loop.new(
            config: @config,
            models_router: @models_router,
            stream_callback: stream_cb,
            tools: @tool_registry,
            prompt_builder: @prompt_builder,
            audit: @audit,
            status_callback:
          )
        end

        def build_tool_registry
          registry = Tools::Registry.new
          register_core_tools(registry)
          register_memory_tools(registry) if @memory_store
          register_sag_tool(registry) if @config.sag.enabled

          if @config.familiars.enabled && @familiars_dispatcher
            registry.register(Tools::SendNotification.new(familiars_dispatcher: @familiars_dispatcher))
          end

          registry
        end

        def register_core_tools(registry)
          [
            Tools::Echo.new,
            Tools::DatetimeNow.new,
            Tools::WorkspaceRead.new,
            Tools::WorkspaceWrite.new,
            Tools::WorkspaceList.new,
            Tools::ShellExec.new(config: @config),
            Tools::WebFetch.new(config: @config),
            Tools::WebExtract.new(config: @config),
            Tools::MQTTPublish.new(config: @config),
            Tools::MQTTSubscribe.new(config: @config)
          ].each { |t| registry.register(t) }
        end

        def register_memory_tools(registry)
          registry.register(Tools::MemorySearch.new(memory_store: @memory_store))
          registry.register(Tools::MemorySave.new(memory_store: @memory_store))
          registry.register(Tools::MemoryDailyLog.new(memory_store: @memory_store))
        end

        def register_sag_tool(registry)
          llm_adapter = build_sag_llm_adapter
          return unless llm_adapter
          return unless sag_backend_available?(logger, @config)

          embedder = @memory_store.respond_to?(:embedder) ? @memory_store.embedder : nil
          factory = SAG::PipelineFactory.new(
            config: @config.sag,
            llm_adapter:,
            embedder:
          )
          registry.register(Tools::WebResearch.new(pipeline_factory: factory))
          logger.info("SAG web_research tool registered")
        rescue StandardError => e
          logger.warn("SAG tool registration failed — web_research unavailable", error: e.message)
        end

        def warn_sag_disabled
          logger.warn("SAG disabled in config — web_research unavailable")
        end

        def build_sag_llm_adapter
          if @models_router
            SAG::LLMAdapter.new(router: @models_router)
          elsif @provider
            SAG::LLMAdapter.new(provider: @provider)
          end
        end

        def build_memory_store
          db_path = @config.memory.db_path
          FileUtils.mkdir_p(File.dirname(db_path))
          db = Sequel.sqlite(db_path)
          local_model_config = @config.models[:local]
          embedder = build_embedder(local_model_config)
          store = Memory::Store.new(config: @config, db:, embedder:)
          store.rebuild_index! if db[:memory_chunks].none?
          store
        rescue StandardError => e
          logger.warn("Memory store initialization failed", error: e.message)
          nil
        end

        def build_embedder(local_model_config)
          return nil unless local_model_config&.base_url

          Memory::Embedder.new(
            base_url: local_model_config.base_url,
            model: @config.memory.embedding_model
          )
        end

        def resolve_model_config
          key = @provider_name.to_sym
          model_config = @config.models[key]
          raise ArgumentError, "Unknown provider: #{@provider_name}" unless model_config

          if @model_override
            attrs = model_config.attributes.merge(default_model: @model_override, model: @model_override)
            ModelConfig.new(attrs)
          else
            model_config
          end
        end

        def load_identity
          soul_path = File.join(@config.agent.workspace_path, "SOUL.md")
          return @agent_name unless File.file?(soul_path)

          line = File.foreach(soul_path).find { |l| l.strip.start_with?("- **Name**") }
          return @agent_name unless line

          match = line.match(/\*\*Name\*\*:\s*(.+)/)
          match ? match[1].strip : @agent_name
        rescue StandardError
          @agent_name
        end

        def setup_scheduler!
          @scheduler_manager = Scheduler::Manager.new(
            config: @config,
            agent_loop: @agent_loop,
            notification: build_notification_service,
            job_store: Scheduler::JobStore.new(db_path: @config.scheduler.db_path)
          )
          @tool_registry.register(Tools::SchedulerManage.new(scheduler_manager: @scheduler_manager))
          @heartbeat = Scheduler::Heartbeat.new(config: @config, scheduler_manager: @scheduler_manager)
          @heartbeat.setup!
        rescue StandardError => e
          logger.error("Scheduler setup failed", error: e.message)
          @scheduler_manager = nil
        end

        def build_notification_service
          service = Scheduler::Notification.new(config: @config)
          interface_fn = lambda { |text, _priority|
            push_info_message("[Scheduler] #{text}")
            refresh_all
          }
          service.deliver_fn = wrap_deliver_fn_with_familiars(
            original_fn: interface_fn,
            dispatcher: @familiars_dispatcher,
            title: "Homunculus Scheduler"
          )
          service
        end

        def load_tier_descriptions_from_models_toml
          return [] unless File.file?(models_toml_path)

          toml = TomlRB.load_file(models_toml_path)
          tiers = toml["tiers"] || {}
          tiers.map do |name, cfg|
            desc = cfg.is_a?(Hash) ? (cfg["description"] || "") : ""
            "  #{name} — #{desc}".strip
          end.reject { |line| line.end_with?(" — ") }
        end
      end
    end
  end
end
