# frozen_string_literal: true

require "spec_helper"
require "sequel"

RSpec.describe Homunculus::Agent::Router do
  let(:config) { Homunculus::Config.load("config/default.toml") }
  let(:budget_db) { Sequel.sqlite }
  let(:budget) do
    Homunculus::Agent::BudgetTracker.new(daily_limit_usd: 2.0, db: budget_db)
  end
  let(:router) { described_class.new(config:, budget:) }
  let(:session) { Homunculus::Session.new }

  def messages_with(content)
    [{ role: "user", content: }]
  end

  describe "#select_model" do
    context "with simple messages" do
      it "routes short messages to ollama" do
        selection = router.select_model(messages: messages_with("Hello, how are you?"), session:)

        expect(selection.provider).to eq(:ollama)
        expect(selection.reason).to eq(:simple_question)
      end

      it "routes empty messages to ollama" do
        selection = router.select_model(messages: [], session:)

        expect(selection.provider).to eq(:ollama)
        expect(selection.reason).to eq(:simple_question)
      end
    end

    context "with code-related messages" do
      it "routes 'implement' requests to anthropic" do
        selection = router.select_model(
          messages: messages_with("Can you implement a sorting algorithm?"),
          session:
        )

        expect(selection.provider).to eq(:anthropic)
        expect(selection.reason).to eq(:code_generation)
      end

      it "routes 'refactor' requests to anthropic" do
        selection = router.select_model(
          messages: messages_with("Please refactor this module to use dependency injection"),
          session:
        )

        expect(selection.provider).to eq(:anthropic)
        expect(selection.reason).to eq(:code_generation)
      end

      it "routes 'write code' requests to anthropic" do
        selection = router.select_model(
          messages: messages_with("write code to parse CSV files"),
          session:
        )

        expect(selection.provider).to eq(:anthropic)
        expect(selection.reason).to eq(:code_generation)
      end

      it "routes 'fix this' requests to anthropic" do
        selection = router.select_model(
          messages: messages_with("Can you fix this bug in the parser?"),
          session:
        )

        expect(selection.provider).to eq(:anthropic)
        expect(selection.reason).to eq(:code_generation)
      end

      it "routes 'review this' requests to anthropic" do
        selection = router.select_model(
          messages: messages_with("Please review this pull request"),
          session:
        )

        expect(selection.provider).to eq(:anthropic)
        expect(selection.reason).to eq(:code_generation)
      end
    end

    context "with reasoning-related messages" do
      it "routes 'analyze' requests to anthropic" do
        selection = router.select_model(
          messages: messages_with("Can you analyze the performance of this query?"),
          session:
        )

        expect(selection.provider).to eq(:anthropic)
        expect(selection.reason).to eq(:complex_reasoning)
      end

      it "routes 'compare' requests to anthropic" do
        selection = router.select_model(
          messages: messages_with("compare Redis and Memcached for our use case"),
          session:
        )

        expect(selection.provider).to eq(:anthropic)
        expect(selection.reason).to eq(:complex_reasoning)
      end

      it "routes 'pros and cons' requests to anthropic" do
        selection = router.select_model(
          messages: messages_with("What are the pros and cons of microservices?"),
          session:
        )

        expect(selection.provider).to eq(:anthropic)
        expect(selection.reason).to eq(:complex_reasoning)
      end
    end

    context "with long messages" do
      it "routes messages over 500 chars to anthropic as complex_reasoning" do
        long_text = "a" * 501
        selection = router.select_model(messages: messages_with(long_text), session:)

        expect(selection.provider).to eq(:anthropic)
        expect(selection.reason).to eq(:complex_reasoning)
      end

      it "routes messages over 2000 chars to anthropic as context_overflow" do
        very_long_text = "a" * 2001
        selection = router.select_model(messages: messages_with(very_long_text), session:)

        expect(selection.provider).to eq(:anthropic)
        expect(selection.reason).to eq(:context_overflow)
      end
    end

    context "with multi-tool planning" do
      it "routes to anthropic when 3+ recent messages have tool calls" do
        messages = [
          { role: "user", content: "Do task 1" },
          { role: "assistant", content: "OK", tool_calls: [double] },
          { role: "tool", content: "done" },
          { role: "assistant", content: "Next", tool_calls: [double] },
          { role: "tool", content: "done" },
          { role: "assistant", content: "More", tool_calls: [double] },
          { role: "user", content: "continue" }
        ]

        selection = router.select_model(messages:, session:)

        expect(selection.provider).to eq(:anthropic)
        expect(selection.reason).to eq(:multi_tool_planning)
      end
    end

    context "with budget exhausted" do
      before do
        # Spend the entire budget
        budget.record_usage(model: "claude-sonnet-4", input_tokens: 500_000, output_tokens: 50_000)
      end

      it "routes to ollama regardless of task classification" do
        selection = router.select_model(
          messages: messages_with("write code to implement a web server"),
          session:
        )

        expect(selection.provider).to eq(:ollama)
        expect(selection.reason).to eq(:budget_exhausted)
      end

      it "still routes simple tasks to ollama normally" do
        selection = router.select_model(messages: messages_with("hello"), session:)

        expect(selection.provider).to eq(:ollama)
        expect(selection.reason).to eq(:simple_question)
      end
    end

    context "with user override (forced_provider)" do
      it "returns forced :anthropic when session has forced_provider" do
        session.forced_provider = :anthropic

        selection = router.select_model(messages: messages_with("hello"), session:)

        expect(selection.provider).to eq(:anthropic)
        expect(selection.reason).to eq(:user_override)
      end

      it "returns forced :ollama when session has forced_provider" do
        session.forced_provider = :ollama

        selection = router.select_model(
          messages: messages_with("write code to implement a web server"),
          session:
        )

        expect(selection.provider).to eq(:ollama)
        expect(selection.reason).to eq(:user_override)
      end

      it "ignores budget when user forces anthropic" do
        session.forced_provider = :anthropic
        budget.record_usage(model: "claude-sonnet-4", input_tokens: 500_000, output_tokens: 50_000)

        selection = router.select_model(messages: messages_with("hello"), session:)

        expect(selection.provider).to eq(:anthropic)
        expect(selection.reason).to eq(:user_override)
      end
    end

    context "with nil session" do
      it "works without a session" do
        selection = router.select_model(messages: messages_with("hello"), session: nil)

        expect(selection.provider).to eq(:ollama)
        expect(selection.reason).to eq(:simple_question)
      end
    end

    context "with escalation disabled" do
      around do |example|
        original = ENV.fetch("ESCALATION_ENABLED", nil)
        ENV["ESCALATION_ENABLED"] = "false"
        example.run
      ensure
        if original
          ENV["ESCALATION_ENABLED"] = original
        else
          ENV.delete("ESCALATION_ENABLED")
        end
      end

      let(:config) { Homunculus::Config.load("config/default.toml") }

      it "routes code tasks to ollama with :escalation_disabled" do
        selection = router.select_model(
          messages: messages_with("write code to implement a web server"),
          session:
        )

        expect(selection.provider).to eq(:ollama)
        expect(selection.reason).to eq(:escalation_disabled)
      end

      it "routes reasoning tasks to ollama with :escalation_disabled" do
        selection = router.select_model(
          messages: messages_with("analyze the performance of this query"),
          session:
        )

        expect(selection.provider).to eq(:ollama)
        expect(selection.reason).to eq(:escalation_disabled)
      end

      it "routes long messages to ollama with :escalation_disabled" do
        long_text = "a" * 2001
        selection = router.select_model(messages: messages_with(long_text), session:)

        expect(selection.provider).to eq(:ollama)
        expect(selection.reason).to eq(:escalation_disabled)
      end

      it "still respects user override to :ollama" do
        session.forced_provider = :ollama

        selection = router.select_model(
          messages: messages_with("write code to implement a web server"),
          session:
        )

        expect(selection.provider).to eq(:ollama)
        expect(selection.reason).to eq(:user_override)
      end

      it "still respects user override to :anthropic (user explicitly forced)" do
        session.forced_provider = :anthropic

        selection = router.select_model(messages: messages_with("hello"), session:)

        expect(selection.provider).to eq(:anthropic)
        expect(selection.reason).to eq(:user_override)
      end
    end
  end

  describe "ModelSelection" do
    it "is a Data class with provider and reason" do
      selection = Homunculus::Agent::ModelSelection.new(provider: :ollama, reason: :simple_question)

      expect(selection.provider).to eq(:ollama)
      expect(selection.reason).to eq(:simple_question)
      expect(selection).to be_frozen
    end
  end
end
