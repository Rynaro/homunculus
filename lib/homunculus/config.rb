# frozen_string_literal: true

require "toml-rb"
require "dry-struct"
require "dry-types"

module Homunculus
  module Types
    include Dry.Types()
  end

  class GatewayConfig < Dry::Struct
    transform_keys(&:to_sym)

    attribute :host, Types::Strict::String.default("127.0.0.1")
    attribute :port, Types::Strict::Integer.default(18_789)
    attribute :auth_token_hash, Types::Strict::String.default("")

    def validate!
      raise SecurityError, "Gateway MUST bind to 127.0.0.1, got #{host}" unless host == "127.0.0.1"
    end
  end

  class ModelConfig < Dry::Struct
    transform_keys(&:to_sym)

    attribute :provider, Types::Strict::String
    attribute :default_model, Types::Strict::String.optional.default(nil)
    attribute :model, Types::Strict::String.optional.default(nil)
    attribute :base_url, Types::Strict::String.optional.default(nil)
    attribute :context_window, Types::Strict::Integer
    attribute :temperature, Types::Strict::Float
    attribute :daily_budget_usd, Types::Strict::Float.optional.default(nil)
    attribute :api_key, Types::Strict::String.optional.default(nil)
    attribute :enabled, Types::Strict::Bool.default(true)
    attribute :timeout_seconds, Types::Coercible::Integer.optional.default(nil)
  end

  class AgentConfig < Dry::Struct
    transform_keys(&:to_sym)

    attribute :max_turns, Types::Strict::Integer.default(25)
    attribute :max_execution_time_seconds, Types::Strict::Integer.default(300)
    attribute :workspace_path, Types::Strict::String.default("./workspace")
  end

  class SandboxConfig < Dry::Struct
    transform_keys(&:to_sym)

    attribute :enabled, Types::Strict::Bool.default(true)
    attribute :image, Types::Strict::String.default("homunculus-sandbox:latest")
    attribute :network, Types::Strict::String.default("none")
    attribute :memory_limit, Types::Strict::String.default("512m")
    attribute :cpu_limit, Types::Strict::String.default("1.0")
    attribute :read_only_root, Types::Strict::Bool.default(true)
    attribute :drop_capabilities, Types::Strict::Array.of(Types::Strict::String).default(["ALL"].freeze)
    attribute :no_new_privileges, Types::Strict::Bool.default(true)
  end

  class ToolsConfig < Dry::Struct
    transform_keys(&:to_sym)

    attribute :approval_mode, Types::Strict::String.default("elevated")
    attribute :safe_commands, Types::Strict::Array.of(Types::Strict::String).default([].freeze)
    attribute :blocked_patterns, Types::Strict::Array.of(Types::Strict::String).default([].freeze)
    attribute :sandbox, SandboxConfig
  end

  class MemoryConfig < Dry::Struct
    transform_keys(&:to_sym)

    attribute :backend, Types::Strict::String.default("sqlite")
    attribute :db_path, Types::Strict::String.default("./data/memory.db")
    attribute :embedding_provider, Types::Strict::String.default("local")
    attribute :embedding_model, Types::Strict::String.default("nomic-embed-text")
    attribute :max_context_tokens, Types::Strict::Integer.default(4096)
  end

  class SecurityConfig < Dry::Struct
    transform_keys(&:to_sym)

    attribute :audit_log_path, Types::Strict::String.default("./data/audit.jsonl")
    attribute :require_confirmation, Types::Strict::Array.of(Types::Strict::String).default([].freeze)
  end

  class MQTTConfig < Dry::Struct
    transform_keys(&:to_sym)

    attribute :broker_host, Types::Strict::String.default("localhost")
    attribute :broker_port, Types::Strict::Integer.default(1883)
    attribute :username, Types::Strict::String.default("")
    attribute :password, Types::Strict::String.default("")
    attribute :client_id, Types::Strict::String.default("homunculus-agent")
    attribute :allowed_topics, Types::Strict::Array.of(Types::Strict::String).default([].freeze)
    attribute :blocked_topics, Types::Strict::Array.of(Types::Strict::String).default([].freeze)
  end

  class HeartbeatConfig < Dry::Struct
    transform_keys(&:to_sym)

    attribute :enabled, Types::Strict::Bool.default(true)
    attribute :cron, Types::Strict::String.default("*/30 8-22 * * *")
    attribute :model, Types::Strict::String.default("local")
    attribute :active_hours_start, Types::Strict::Integer.default(8)
    attribute :active_hours_end, Types::Strict::Integer.default(22)
    attribute :timezone, Types::Strict::String.default("America/Sao_Paulo")
  end

  class NotificationConfig < Dry::Struct
    transform_keys(&:to_sym)

    attribute :max_per_hour, Types::Strict::Integer.default(10)
    attribute :quiet_hours_queue, Types::Strict::Bool.default(true)
  end

  class SchedulerConfig < Dry::Struct
    transform_keys(&:to_sym)

    attribute :enabled, Types::Strict::Bool.default(true)
    attribute :db_path, Types::Strict::String.default("./data/scheduler.db")
    attribute :heartbeat, HeartbeatConfig
    attribute :notification, NotificationConfig
  end

  class TelegramConfig < Dry::Struct
    transform_keys(&:to_sym)

    attribute :enabled, Types::Strict::Bool.default(false)
    attribute :bot_token, Types::Strict::String.optional.default(nil)
    attribute :allowed_user_ids, Types::Strict::Array.of(Types::Strict::Integer).default([].freeze)
    attribute :session_timeout_minutes, Types::Strict::Integer.default(30)
    attribute :max_message_length, Types::Strict::Integer.default(4096)
    attribute :typing_indicator, Types::Strict::Bool.default(true)
  end

  class Config
    attr_reader :gateway, :models, :agent, :tools, :memory, :security, :telegram, :mqtt, :scheduler

    def self.load(path = "config/default.toml")
      raw = TomlRB.load_file(path)
      override_from_env!(raw)
      config_path = File.expand_path(path)
      new(raw, config_path: config_path)
    end

    # Whether escalation to remote models (e.g. Claude) is enabled.
    # Returns false when escalation config is missing or explicitly disabled.
    def escalation_enabled?
      @models[:escalation]&.enabled != false
    end

    def initialize(raw, config_path: nil)
      if config_path
        raw = raw.dup
        raw["agent"] = (raw["agent"] || {}).dup
        wp = raw["agent"]["workspace_path"] || "./workspace"
        project_root = File.dirname(config_path, 2)
        raw["agent"]["workspace_path"] = File.expand_path(wp, project_root)
      end
      @gateway = GatewayConfig.new(raw.fetch("gateway", {}))
      @models = build_models(raw.fetch("models", {}))
      @agent = AgentConfig.new(raw.fetch("agent", {}))
      tools_raw = raw.fetch("tools", {})
      mqtt_raw = tools_raw.fetch("mqtt", {})
      @tools = build_tools(tools_raw)
      @memory = MemoryConfig.new(raw.fetch("memory", {}))
      security_raw = raw.fetch("security", {}).dup
      security_raw.delete("content_pipeline") # Handled separately, not part of SecurityConfig struct
      @security = SecurityConfig.new(security_raw)
      @telegram = TelegramConfig.new(raw.dig("interfaces", "telegram") || {})
      @mqtt = build_mqtt(mqtt_raw)
      @scheduler = build_scheduler(raw.fetch("scheduler", {}))

      @gateway.validate!
    end

    private

    def build_models(raw)
      raw.each_with_object({}) do |(name, attrs), hash|
        hash[name.to_sym] = ModelConfig.new(attrs)
      end
    end

    def build_tools(raw)
      sandbox_raw = raw.delete("sandbox") || {}
      raw.delete("mqtt") # MQTT is handled separately
      raw.delete("web") # Web config is accessed via tools.web but not part of ToolsConfig struct
      tools_hash = raw.transform_keys(&:to_sym)
      tools_hash[:sandbox] = SandboxConfig.new(sandbox_raw)
      ToolsConfig.new(tools_hash)
    end

    def build_scheduler(raw)
      heartbeat_raw = raw.delete("heartbeat") || {}
      notification_raw = raw.delete("notification") || {}
      scheduler_hash = raw.transform_keys(&:to_sym)
      scheduler_hash[:heartbeat] = HeartbeatConfig.new(heartbeat_raw)
      scheduler_hash[:notification] = NotificationConfig.new(notification_raw)
      SchedulerConfig.new(scheduler_hash)
    end

    def build_mqtt(raw)
      mqtt_hash = raw.transform_keys(&:to_sym)

      # Override credentials from environment variables
      mqtt_hash[:username] = ENV.fetch("MQTT_USERNAME", mqtt_hash.fetch(:username, ""))
      mqtt_hash[:password] = ENV.fetch("MQTT_PASSWORD", mqtt_hash.fetch(:password, ""))

      MQTTConfig.new(mqtt_hash)
    end

    class << self
      private

      def override_from_env!(raw)
        # Environment variables take precedence over config file
        raw.dig("models", "escalation")&.merge!(
          "api_key" => ENV.fetch("ANTHROPIC_API_KEY", nil)
        )

        # Escalation enabled/disabled from env (local-only mode for experimenting with local models)
        if ENV.key?("ESCALATION_ENABLED") && raw.dig("models", "escalation")
          raw["models"]["escalation"]["enabled"] = ENV.fetch("ESCALATION_ENABLED").downcase == "true"
        end

        # Gateway auth token from env
        if ENV.key?("GATEWAY_AUTH_TOKEN_HASH")
          raw["gateway"] ||= {}
          raw["gateway"]["auth_token_hash"] = ENV.fetch("GATEWAY_AUTH_TOKEN_HASH")
        end

        # Telegram bot token from env
        if ENV.key?("TELEGRAM_BOT_TOKEN")
          raw["interfaces"] ||= {}
          raw["interfaces"]["telegram"] ||= {}
          raw["interfaces"]["telegram"]["bot_token"] = ENV.fetch("TELEGRAM_BOT_TOKEN")
        end

        # Ollama base URL from env (supports host or dockerized Ollama)
        if ENV.key?("OLLAMA_BASE_URL")
          raw["models"] ||= {}
          raw["models"]["local"] ||= {}
          raw["models"]["local"]["base_url"] = ENV.fetch("OLLAMA_BASE_URL")
        end

        # Ollama request timeout from env (e.g. Docker / slow instances)
        return unless ENV.key?("OLLAMA_TIMEOUT_SECONDS")

        raw["models"] ||= {}
        raw["models"]["local"] ||= {}
        raw["models"]["local"]["timeout_seconds"] = ENV.fetch("OLLAMA_TIMEOUT_SECONDS").to_i
      end
    end
  end
end
