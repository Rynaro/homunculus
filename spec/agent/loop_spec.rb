# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe Homunculus::Agent::Loop do
  let(:config) { Homunculus::Config.load("config/default.toml") }
  let(:session) { Homunculus::Session.new }

  let(:loop_instance) do
    described_class.new(
      config:,
      provider:,
      tools: tool_registry,
      prompt_builder:,
      audit:
    )
  end
  let(:provider) { instance_double(Homunculus::Agent::ModelProvider) }
  let(:prompt_builder) do
    Homunculus::Agent::PromptBuilder.new(
      workspace_path: config.agent.workspace_path,
      tool_registry: tool_registry
    )
  end
  let(:tool_registry) { Homunculus::Tools::Registry.new }
  let(:audit) { Homunculus::Security::AuditLogger.new(audit_file.path) }
  let(:audit_file) { Tempfile.new(["audit", ".jsonl"]) }

  after do
    audit_file.close
    audit_file.unlink
  end

  before do
    tool_registry.register(Homunculus::Tools::Echo.new)
    tool_registry.register(Homunculus::Tools::DatetimeNow.new)
    tool_registry.register(Homunculus::Tools::WorkspaceWrite.new)
  end

  describe "AgentResult" do
    it "stores optional tier, model, escalated_from when provided" do
      result = Homunculus::Agent::AgentResult.completed(
        "OK",
        session:,
        tier: "workhorse",
        model: "qwen3:14b",
        escalated_from: nil
      )
      expect(result.status).to eq(:completed)
      expect(result.response).to eq("OK")
      expect(result.tier).to eq("workhorse")
      expect(result.model).to eq("qwen3:14b")
      expect(result.escalated_from).to be_nil
    end

    it "stores escalated_from when provided" do
      result = Homunculus::Agent::AgentResult.completed(
        "OK",
        session:,
        tier: "cloud_fast",
        model: "claude-haiku",
        escalated_from: "workhorse"
      )
      expect(result.escalated_from).to eq("workhorse")
    end

    it "leaves tier/model/escalated_from nil when not provided (backward compat)" do
      result = Homunculus::Agent::AgentResult.completed("OK", session:)
      expect(result.tier).to be_nil
      expect(result.model).to be_nil
      expect(result.escalated_from).to be_nil
    end

    it "stores context_window when provided" do
      result = Homunculus::Agent::AgentResult.completed(
        "OK",
        session:,
        context_window: 32_768
      )
      expect(result.context_window).to eq(32_768)
    end

    it "leaves context_window nil when not provided" do
      result = Homunculus::Agent::AgentResult.completed("OK", session:)
      expect(result.context_window).to be_nil
    end

    it "stores context_window on pending_confirmation result" do
      tool_call = Homunculus::Agent::ModelProvider::ToolCall.new(
        id: "tc-1", name: "shell_exec", arguments: {}
      )
      result = Homunculus::Agent::AgentResult.pending_confirmation(tool_call, session:, context_window: 16_384)
      expect(result.context_window).to eq(16_384)
    end
  end

  def make_response(content:, tool_calls: nil, stop_reason: "end_turn", raw_response: {})
    Homunculus::Agent::ModelProvider::Response.new(
      content:,
      tool_calls:,
      usage: Homunculus::Agent::ModelProvider::TokenUsage.new(input_tokens: 100, output_tokens: 50),
      model: "test-model",
      stop_reason:,
      raw_response:
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

      it "returns tier/model/escalated_from when raw_response has them (models_router)" do
        raw = instance_double(
          Homunculus::Agent::Models::Response,
          tier: :workhorse, model: "qwen3:14b", escalated_from: nil
        )
        allow(provider).to receive(:complete).and_return(
          make_response(content: "Hi", raw_response: raw)
        )
        result = loop_instance.run("Hello", session)
        expect(result.status).to eq(:completed)
        expect(result.tier).to eq("workhorse")
        expect(result.model).to eq("qwen3:14b")
        expect(result.escalated_from).to be_nil
      end

      it "returns escalated_from when raw_response indicates escalation" do
        raw = instance_double(
          Homunculus::Agent::Models::Response,
          tier: :cloud_fast, model: "claude-haiku", escalated_from: :workhorse
        )
        allow(provider).to receive(:complete).and_return(
          make_response(content: "Hi", raw_response: raw)
        )
        result = loop_instance.run("Hello", session)
        expect(result.tier).to eq("cloud_fast")
        expect(result.model).to eq("claude-haiku")
        expect(result.escalated_from).to eq("workhorse")
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

  describe "session tier override (models_router mode)" do
    def make_models_response_simple(content)
      double(
        content: content,
        tool_calls: nil,
        usage: { prompt_tokens: 10, completion_tokens: 5 },
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

    context "when routing_enabled is false and forced_tier is set" do
      it "passes forced_tier to router.generate on every call" do
        session.forced_tier = :coder
        session.routing_enabled = false
        allow(models_router).to receive(:generate).and_return(make_models_response_simple("answer"))

        loop_with_router.run("Hello", session)

        expect(models_router).to have_received(:generate).with(hash_including(tier: :coder))
      end

      it "keeps forced_tier set after the call" do
        session.forced_tier = :coder
        session.routing_enabled = false
        allow(models_router).to receive(:generate).and_return(make_models_response_simple("answer"))

        loop_with_router.run("Hello", session)

        expect(session.forced_tier).to eq(:coder)
      end
    end

    context "when routing_enabled is true and forced_tier is set (one-shot override)" do
      it "passes forced_tier on the first generate call" do
        session.forced_tier = :workhorse
        session.routing_enabled = true
        allow(models_router).to receive(:generate).and_return(make_models_response_simple("answer"))

        loop_with_router.run("Hello", session)

        expect(models_router).to have_received(:generate).with(hash_including(tier: :workhorse))
      end

      it "clears forced_tier after the first call" do
        session.forced_tier = :workhorse
        session.routing_enabled = true
        allow(models_router).to receive(:generate).and_return(make_models_response_simple("answer"))

        loop_with_router.run("Hello", session)

        expect(session.forced_tier).to be_nil
        expect(session.first_message_sent).to be true
      end
    end

    context "when no forced_tier is set" do
      it "passes tier: nil to router.generate" do
        allow(models_router).to receive(:generate).and_return(make_models_response_simple("answer"))

        loop_with_router.run("Hello", session)

        expect(models_router).to have_received(:generate).with(hash_including(tier: nil))
      end
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

  describe "tool status callbacks" do
    it "pairs tool_start and tool_end on success" do
      status_callback = instance_double(Proc, call: nil)
      loop_with_status_callback = described_class.new(
        config:,
        provider:,
        tools: tool_registry,
        prompt_builder:,
        audit:,
        status_callback:
      )
      tool_call = make_tool_call(name: "echo", arguments: { text: "hello" })
      allow(tool_registry).to receive(:execute).and_return(Homunculus::Tools::Result.ok("hello"))

      loop_with_status_callback.send(:execute_tool, tool_call, session)

      expect(status_callback).to have_received(:call).with(:tool_start, "echo").ordered
      expect(status_callback).to have_received(:call).with(:tool_end, "echo").ordered
    end

    it "pairs tool_start and tool_end when the tool times out" do
      status_callback = instance_double(Proc, call: nil)
      loop_with_status_callback = described_class.new(
        config:,
        provider:,
        tools: tool_registry,
        prompt_builder:,
        audit:,
        status_callback:
      )
      tool_call = make_tool_call(name: "echo", arguments: { text: "hello" })
      allow(Timeout).to receive(:timeout).and_raise(Timeout::Error)

      result = loop_with_status_callback.send(:execute_tool, tool_call, session)

      expect(result.success).to be false
      expect(result.error).to include("timed out")
      expect(status_callback).to have_received(:call).with(:tool_start, "echo").ordered
      expect(status_callback).to have_received(:call).with(:tool_end, "echo").ordered
    end

    it "pairs tool_start and tool_end when the tool raises" do
      status_callback = instance_double(Proc, call: nil)
      loop_with_status_callback = described_class.new(
        config:,
        provider:,
        tools: tool_registry,
        prompt_builder:,
        audit:,
        status_callback:
      )
      tool_call = make_tool_call(name: "echo", arguments: { text: "hello" })
      allow(tool_registry).to receive(:execute).and_raise(StandardError, "boom")

      result = loop_with_status_callback.send(:execute_tool, tool_call, session)

      expect(result.success).to be false
      expect(result.error).to include("Tool error: boom")
      expect(status_callback).to have_received(:call).with(:tool_start, "echo").ordered
      expect(status_callback).to have_received(:call).with(:tool_end, "echo").ordered
    end
  end
end
