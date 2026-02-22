# frozen_string_literal: true

module Homunculus
  module Agent
    # Selects the appropriate model provider for each request.
    # Defaults to local (Ollama) and escalates to Claude when needed.
    class Router
      include SemanticLogger::Loggable

      LOCAL_TASKS = %i[simple_question tool_dispatch casual_chat status_check
                       memory_retrieval heartbeat simple_formatting].freeze

      CLAUDE_TASKS = %i[complex_reasoning code_generation code_review
                        multi_tool_planning document_writing architecture_design
                        prompt_engineering research_synthesis debugging
                        context_overflow].freeze

      CODE_PATTERNS = [
        "write code", "implement", "refactor", "debug this", "function",
        "class ", "script", "fix this", "review this", "code review",
        "pull request", "unit test", "test case", "write a program",
        "code that", "write me a"
      ].freeze

      REASONING_PATTERNS = [
        "analyze", "compare", "evaluate", "trade-off", "pros and cons",
        "architecture", "design pattern", "strategy", "plan for",
        "explain why", "how should", "what approach", "recommend",
        "trade off", "versus", "advantages"
      ].freeze

      def initialize(config:, budget:)
        @config = config
        @budget = budget
      end

      attr_reader :budget

      # Selects the model provider for the current request.
      # Returns a ModelSelection with :provider (:ollama or :anthropic) and :reason.
      def select_model(messages:, tools: nil, session: nil)
        # 1. Explicit user override (via /escalate, /local commands)
        return ModelSelection.new(provider: session.forced_provider, reason: :user_override) if session&.forced_provider

        # 2. If escalation is disabled, always route to local (local-only mode)
        if escalation_disabled?
          logger.debug("Escalation disabled, routing to local")
          return ModelSelection.new(provider: :ollama, reason: :escalation_disabled)
        end

        # 3. Classify the task
        task_type = classify(messages)

        # 4. If classification says Claude, check budget first
        if CLAUDE_TASKS.include?(task_type)
          unless @budget.can_use_claude?
            logger.info("Budget exhausted, routing to local", task_type:)
            return ModelSelection.new(provider: :ollama, reason: :budget_exhausted)
          end

          return ModelSelection.new(provider: :anthropic, reason: task_type)
        end

        # 5. Default to local
        ModelSelection.new(provider: :ollama, reason: task_type)
      end

      private

      def escalation_disabled?
        escalation = @config.models[:escalation]
        escalation.nil? || escalation.enabled == false
      end

      def classify(messages)
        return :simple_question if messages.empty?

        last_msg = messages.last[:content].to_s

        # Very long messages likely need stronger reasoning
        return :context_overflow if last_msg.length > 2000
        return :complex_reasoning if last_msg.length > 500

        last_lower = last_msg.downcase

        # Check for code-related indicators
        return :code_generation if code_indicators?(last_lower)

        # Check for reasoning/analysis indicators
        return :complex_reasoning if reasoning_indicators?(last_lower)

        # Check for multi-tool planning (many recent tool calls suggest complex orchestration)
        recent_tool_count = messages.last(6).count { |m| m[:tool_calls] }
        return :multi_tool_planning if recent_tool_count >= 3

        :simple_question
      end

      def code_indicators?(text)
        CODE_PATTERNS.any? { |pattern| text.include?(pattern) }
      end

      def reasoning_indicators?(text)
        REASONING_PATTERNS.any? { |pattern| text.include?(pattern) }
      end
    end

    # Immutable value object representing a model routing decision.
    ModelSelection = Data.define(:provider, :reason)
  end
end
