# frozen_string_literal: true

require "pathname"
require "securerandom"

module Homunculus
  module Agent
    # Manages multiple specialized agents with synchronous execution and
    # content-based routing between agent personas.
    #
    # Each agent is defined by a directory under workspace/agents/ containing:
    # - SOUL.md: Agent persona and instructions
    # - TOOLS.md (optional): Tool-specific configuration
    class MultiAgentManager
      include SemanticLogger::Loggable

      # Patterns for detecting agent-directed messages (e.g., "@coder fix this bug")
      AGENT_MENTION_PATTERN = /\A@(\w+)\s+(.+)/m

      # Keywords that hint at which agent should handle a message
      AGENT_ROUTING_HINTS = {
        coder: ["code", "implement", "refactor", "debug", "function", "class", "test", "bug", "fix", "review", "PR",
                "pull request", "commit", "branch", "git", "compile", "build", "lint"],
        researcher: ["research", "analyze", "compare", "evaluate", "study", "search", "find", "look up", "investigate",
                     "summarize", "source", "reference"],
        home: ["mqtt", "sensor", "temperature", "humidity", "light", "device", "home automation"],
        planner: %w[plan schedule task todo list organize prioritize reminder
                    deadline milestone goal project timeline]
      }.freeze

      def initialize(workspace_path:, config:)
        @workspace_path = Pathname.new(workspace_path)
        @config = config
        @agent_definitions = {}
        @started = false

        load_agents(@workspace_path / "agents")
      end

      # Mark agents as started. All execution uses the synchronous path.
      def start_agents!
        return if @started
        return if @agent_definitions.empty?

        @started = true
        logger.info("Multi-agent manager started",
                    agents: @agent_definitions.keys,
                    mode: :synchronous)
      end

      # Stop and reset the manager.
      def stop!
        @started = false
        logger.info("Multi-agent manager stopped")
      end

      # Route a message to a specific agent and wait for the response.
      #
      # @param agent_name [Symbol, String] target agent name
      # @param message [String] user message
      # @param session [Session] current session
      # @param skill_context [String, nil] injected skill XML
      # @return [Hash] agent response
      def route_to_agent(agent_name, message:, session:, skill_context: nil)
        name = agent_name.to_sym
        name = :default unless @agent_definitions.key?(name)

        request = build_request(message:, session:, skill_context:)
        route_synchronously(name, request)
      end

      # Detect the best agent for a message.
      # Returns the agent name (Symbol) based on @mention or content analysis.
      #
      # @param message [String] user message
      # @return [Array<Symbol, String>] [agent_name, cleaned_message]
      def detect_agent(message)
        # 1. Explicit @mention: "@coder fix this bug"
        if (match = message.match(AGENT_MENTION_PATTERN))
          mentioned = match[1].downcase.to_sym
          return [mentioned, match[2].strip] if @agent_definitions.key?(mentioned)
        end

        # 2. Content-based routing
        agent = classify_message(message)
        [agent, message]
      end

      # Perform agent handoff with context summary.
      #
      # @param from_agent [Symbol] current agent
      # @param to_agent [Symbol] target agent
      # @param session [Session] current session
      # @param reason [String] why the handoff is happening
      # @return [Hash] response from the new agent
      def handoff(from_agent:, to_agent:, session:, reason: nil)
        summary = summarize_context(session)
        handoff_message = "You are taking over from #{from_agent}. " \
                          "Reason: #{reason || "user request"}. " \
                          "Context summary: #{summary}"

        route_to_agent(to_agent, message: handoff_message, session: session)
      end

      # List all available agents with their descriptions.
      def list_agents
        @agent_definitions.map do |name, defn|
          # Extract first paragraph from SOUL.md as description
          desc = defn.soul.lines.find { |l| l.strip.start_with?("You are") }&.strip ||
                 defn.soul.lines.reject { |l| l.strip.empty? || l.start_with?("#") }.first&.strip ||
                 "No description"

          { name: name.to_s, description: desc,
            model_preference: defn.model_preference,
            has_tools_config: !defn.tools_config.nil? }
        end
      end

      # Check if an agent exists.
      def agent_exists?(name)
        @agent_definitions.key?(name.to_sym)
      end

      # Get agent definition.
      def agent_definition(name)
        @agent_definitions[name.to_sym]
      end

      # Number of loaded agents.
      def size
        @agent_definitions.size
      end

      private

      # ── Agent Loading ─────────────────────────────────────────────────

      def load_agents(agents_dir)
        return unless agents_dir.exist?

        agents_dir.children.select(&:directory?).each do |dir|
          soul_path = dir / "SOUL.md"
          next unless soul_path.exist?

          name = dir.basename.to_s
          soul = soul_path.read(encoding: "utf-8")
          tools_path = dir / "TOOLS.md"
          tools_config = tools_path.exist? ? tools_path.read(encoding: "utf-8") : nil

          @agent_definitions[name.to_sym] = AgentDefinition.new(
            name: name,
            soul: soul,
            tools_config: tools_config,
            model_preference: AgentDefinition.extract_model_preference(soul),
            allowed_tools: AgentDefinition.extract_allowed_tools(tools_config)
          )

          logger.debug("Agent loaded", agent: name,
                                       model_preference: @agent_definitions[name.to_sym].model_preference,
                                       tools: @agent_definitions[name.to_sym].allowed_tools.size)
        end

        # Ensure a default agent exists
        unless @agent_definitions.key?(:default)
          @agent_definitions[:default] = AgentDefinition.new(
            name: "default",
            soul: "You are a helpful general-purpose assistant.",
            tools_config: nil,
            model_preference: :auto,
            allowed_tools: []
          )
        end

        logger.info("Agents loaded", count: @agent_definitions.size,
                                     names: @agent_definitions.keys)
      end

      # ── Synchronous Routing ───────────────────────────────────────────

      def route_synchronously(name, request)
        defn = @agent_definitions.fetch(name) { @agent_definitions[:default] }
        provider_configs = build_provider_configs
        worker = AgentWorker.new(defn, provider_configs: provider_configs)
        worker.handle(request)
      end

      # ── Request Building ─────────────────────────────────────────────

      def build_request(message:, session:, skill_context: nil)
        {
          id: SecureRandom.uuid,
          message: message,
          session_context: session.to_shareable,
          skill_context: skill_context,
          timestamp: Time.now.to_f
        }
      end

      # ── Message Classification ───────────────────────────────────────

      def classify_message(message)
        lower = message.downcase

        scores = {}
        AGENT_ROUTING_HINTS.each do |agent, keywords|
          next unless @agent_definitions.key?(agent)

          score = keywords.count { |kw| lower.include?(kw) }
          scores[agent] = score if score.positive?
        end

        return :default if scores.empty?

        scores.max_by { |_, v| v }.first
      end

      # ── Context Helpers ──────────────────────────────────────────────

      def summarize_context(session)
        recent = session.messages.last(6)
        return "No prior context." if recent.empty?

        recent.map do |m|
          role = m[:role].to_s.capitalize
          content = m[:content].to_s
          content = "#{content[0...200]}..." if content.length > 200
          "#{role}: #{content}"
        end.join("\n")
      end

      # ── Provider Config ──────────────────────────────────────────────

      def build_provider_configs
        configs = {}

        if @config.models[:local]
          mc = @config.models[:local]
          configs[:local] = {
            provider: mc.provider,
            base_url: mc.base_url,
            default_model: mc.default_model,
            model: mc.model,
            context_window: mc.context_window,
            temperature: mc.temperature,
            api_key: mc.api_key,
            daily_budget_usd: mc.daily_budget_usd
          }
        end

        if @config.escalation_enabled? && @config.models[:escalation]
          mc = @config.models[:escalation]
          configs[:escalation] = {
            provider: mc.provider,
            base_url: mc.base_url,
            default_model: mc.default_model,
            model: mc.model,
            context_window: mc.context_window,
            temperature: mc.temperature,
            api_key: mc.api_key,
            daily_budget_usd: mc.daily_budget_usd
          }
        end

        configs
      end
    end
  end
end
