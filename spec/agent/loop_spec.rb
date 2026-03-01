# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe Homunculus::Agent::Loop do
  let(:config) { Homunculus::Config.load("config/default.toml") }
  let(:session) { Homunculus::Session.new }
  let(:audit_file) { Tempfile.new(["audit", ".jsonl"]) }
  let(:audit) { Homunculus::Security::AuditLogger.new(audit_file.path) }
  let(:tool_registry) { Homunculus::Tools::Registry.new }
  let(:prompt_builder) do
    Homunculus::Agent::PromptBuilder.new(
      workspace_path: config.agent.workspace_path,
      tool_registry: tool_registry
    )
  end
  let(:provider) { instance_double(Homunculus::Agent::ModelProvider) }

  let(:loop_instance) do
    described_class.new(
      config:,
      provider:,
      tools: tool_registry,
      prompt_builder:,
      audit:
    )
  end

  before do
    tool_registry.register(Homunculus::Tools::Echo.new)
    tool_registry.register(Homunculus::Tools::DatetimeNow.new)
    tool_registry.register(Homunculus::Tools::WorkspaceWrite.new)
  end

  after do
    audit_file.close
    audit_file.unlink
  end

  def make_response(content:, tool_calls: nil, stop_reason: "end_turn")
    Homunculus::Agent::ModelProvider::Response.new(
      content:,
      tool_calls:,
      usage: Homunculus::Agent::ModelProvider::TokenUsage.new(input_tokens: 100, output_tokens: 50),
      model: "test-model",
      stop_reason:,
      raw_response: {}
    )
  end

  def make_tool_call(name:, arguments: {})
    Homunculus::Agent::ModelProvider::ToolCall.new(
      id: SecureRandom.uuid,
      name:,
      arguments:
    )
  end

  describe "#run" do
    context "with a simple text response" do
      before do
        allow(provider).to receive(:complete).and_return(
          make_response(content: "Hello! How can I help you?")
        )
      end

      it "returns a completed result" do
        result = loop_instance.run("Hello", session)

        expect(result.status).to eq(:completed)
        expect(result.response).to eq("Hello! How can I help you?")
      end

      it "adds messages to session" do
        loop_instance.run("Hello", session)

        expect(session.messages.size).to eq(2) # user + assistant
        expect(session.messages.first[:role]).to eq(:user)
        expect(session.messages.last[:role]).to eq(:assistant)
      end

      it "tracks token usage" do
        loop_instance.run("Hello", session)

        expect(session.total_input_tokens).to eq(100)
        expect(session.total_output_tokens).to eq(50)
      end
    end

    context "with tool calls" do
      it "executes tool and continues the loop" do
        tool_call = make_tool_call(name: "echo", arguments: { text: "world" })

        # First call: model wants to use a tool
        tool_response = make_response(
          content: "Let me echo that.",
          tool_calls: [tool_call],
          stop_reason: "tool_use"
        )

        # Second call: model provides final response after tool result
        final_response = make_response(content: "The echo returned: world")

        allow(provider).to receive(:complete)
          .and_return(tool_response, final_response)

        result = loop_instance.run("Echo world", session)

        expect(result.status).to eq(:completed)
        expect(result.response).to eq("The echo returned: world")
      end

      it "handles unknown tools gracefully" do
        tool_call = make_tool_call(name: "nonexistent_tool", arguments: {})

        tool_response = make_response(
          content: nil,
          tool_calls: [tool_call],
          stop_reason: "tool_use"
        )

        final_response = make_response(content: "Sorry, that tool failed.")

        allow(provider).to receive(:complete)
          .and_return(tool_response, final_response)

        result = loop_instance.run("Do something", session)

        # Should continue with error result from tool
        expect(result.status).to eq(:completed)
      end
    end

    context "with confirmation flow" do
      it "returns pending_confirmation for elevated tools" do
        tool_call = make_tool_call(
          name: "workspace_write",
          arguments: { path: "test.txt", content: "hello" }
        )

        response = make_response(
          content: "I'll write that file.",
          tool_calls: [tool_call],
          stop_reason: "tool_use"
        )

        allow(provider).to receive(:complete).and_return(response)

        result = loop_instance.run("Write a file", session)

        expect(result.status).to eq(:pending_confirmation)
        expect(result.pending_tool_call.name).to eq("workspace_write")
        expect(session.pending_tool_call).to eq(result.pending_tool_call)
      end
    end

    context "with max turns exceeded" do
      it "returns an error after exhausting turns" do
        # Always return tool_use to force loop continuation
        tool_call = make_tool_call(name: "echo", arguments: { text: "loop" })
        response = make_response(
          content: nil,
          tool_calls: [tool_call],
          stop_reason: "tool_use"
        )

        allow(provider).to receive(:complete).and_return(response)

        result = loop_instance.run("Loop forever", session)

        expect(result.status).to eq(:error)
        expect(result.error).to include("Max turns")
      end
    end

    context "with max_tokens stop reason" do
      it "returns completed with truncation warning" do
        response = make_response(
          content: "This is a very long resp...",
          stop_reason: "max_tokens"
        )

        allow(provider).to receive(:complete).and_return(response)

        result = loop_instance.run("Long question", session)

        expect(result.status).to eq(:completed)
        expect(result.response).to include("⚠️ Response was truncated")
      end
    end
  end

  describe "#confirm_tool" do
    it "executes the pending tool and continues" do
      tool_call = make_tool_call(
        name: "workspace_write",
        arguments: { path: "test.txt", content: "hello" }
      )

      # Set up pending state
      session.pending_tool_call = tool_call
      session.add_message(role: :user, content: "Write a file")
      session.add_message(role: :assistant, content: "I'll write that.", tool_calls: [tool_call])

      # After confirmation, model gives final response
      final_response = make_response(content: "File written successfully.")
      allow(provider).to receive(:complete).and_return(final_response)

      # Stub the workspace to avoid actual file write
      allow_any_instance_of(Homunculus::Tools::WorkspaceWrite).to receive(:resolve_workspace)
        .and_return(Dir.mktmpdir)

      result = loop_instance.confirm_tool(session)

      expect(result.status).to eq(:completed)
      expect(session.pending_tool_call).to be_nil
    end

    it "returns error when no pending tool call" do
      result = loop_instance.confirm_tool(session)

      expect(result.status).to eq(:error)
      expect(result.error).to include("No pending tool call")
    end
  end

  describe "#deny_tool" do
    it "adds denial result and continues" do
      tool_call = make_tool_call(
        name: "workspace_write",
        arguments: { path: "test.txt", content: "hello" }
      )

      session.pending_tool_call = tool_call
      session.add_message(role: :user, content: "Write a file")
      session.add_message(role: :assistant, content: "I'll write that.", tool_calls: [tool_call])

      final_response = make_response(content: "OK, I won't write that file.")
      allow(provider).to receive(:complete).and_return(final_response)

      result = loop_instance.deny_tool(session)

      expect(result.status).to eq(:completed)
      expect(session.pending_tool_call).to be_nil
      # Should have a tool result indicating denial
      tool_msg = session.messages.find { |m| m[:role] == :tool }
      expect(tool_msg[:content]).to include("denied")
    end
  end

  describe "compaction integration" do
    def make_models_response(content)
      double(
        content: content,
        tool_calls: nil,
        usage: { prompt_tokens: 100, completion_tokens: 50 },
        model: "test-model",
        finish_reason: "stop",
        provider: :ollama
      )
    end

    let(:models_router) { instance_double(Homunculus::Agent::Models::Router) }

    let(:loop_with_router) do
      described_class.new(
        config:,
        models_router:,
        tools: tool_registry,
        prompt_builder:,
        audit:
      )
    end

    context "when messages exceed compaction threshold" do
      it "triggers compaction and replaces session messages" do
        # Fill session with enough messages to exceed the conversation budget threshold
        # context_window=32768, conversation_pct=0.40 → 13107 tokens
        # threshold at 0.75 → ~9830 tokens
        40.times do |i|
          session.add_message(role: :user, content: "Question #{i} #{"detailed padding content " * 40}")
          session.add_message(role: :assistant, content: "Answer #{i} #{"detailed padding content " * 40}")
        end

        original_count = session.messages.size
        allow(models_router).to receive(:generate).and_return(make_models_response("Here is your answer."))

        result = loop_with_router.run("New question", session)

        expect(result.status).to eq(:completed)
        # After compaction, messages should be fewer than original + new messages
        expect(session.messages.size).to be < original_count
      end
    end

    context "when messages are under compaction threshold" do
      it "does not trigger compaction" do
        allow(models_router).to receive(:generate).and_return(make_models_response("Here is your answer."))

        result = loop_with_router.run("Hello", session)

        expect(result.status).to eq(:completed)
        # Should have exactly user + assistant messages
        expect(session.messages.size).to eq(2)
      end
    end

    context "when compaction is disabled in single-provider mode" do
      it "does not trigger compaction" do
        # Single-provider mode (no models_router) — compactor is nil
        20.times do |i|
          session.add_message(role: :user, content: "Question #{i} #{"padding " * 30}")
          session.add_message(role: :assistant, content: "Answer #{i} #{"padding " * 30}")
        end

        allow(provider).to receive(:complete).and_return(
          make_response(content: "Answer")
        )

        original_count = session.messages.size
        loop_instance.run("New question", session)

        # Messages should only grow (user + assistant added), not shrink
        expect(session.messages.size).to eq(original_count + 2)
      end
    end
  end
end
