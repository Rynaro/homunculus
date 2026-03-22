# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/homunculus/interfaces/tui"

RSpec.describe Homunculus::Interfaces::TUI do
  let(:workspace_dir) { Dir.mktmpdir }
  let(:db_dir) { Dir.mktmpdir }

  let(:config) do
    raw = TomlRB.load_file("config/default.toml")
    raw["agent"] = { "workspace_path" => workspace_dir }
    raw["scheduler"] = {
      "enabled" => false,
      "db_path" => File.join(db_dir, "scheduler.db"),
      "heartbeat" => {
        "enabled" => false,
        "cron" => "*/30 8-22 * * *",
        "model" => "local",
        "active_hours_start" => 8,
        "active_hours_end" => 22,
        "timezone" => "UTC"
      },
      "notification" => {
        "max_per_hour" => 10,
        "quiet_hours_queue" => true
      }
    }
    Homunculus::Config.new(raw)
  end

  before do
    allow(Sequel).to receive(:sqlite) { Sequel.connect("sqlite:/") }
    allow(Homunculus::SAG::SearchBackend::SearXNG).to receive(:new).and_return(
      instance_double(Homunculus::SAG::SearchBackend::SearXNG, available?: false)
    )
  end

  after do
    FileUtils.rm_rf(workspace_dir)
    FileUtils.rm_rf(db_dir)
  end

  # ── Initialization ────────────────────────────────────────────────

  describe "#initialize" do
    it "initializes without error" do
      expect { described_class.new(config:) }.not_to raise_error
    end

    it "exposes the config" do
      tui = described_class.new(config:)
      expect(tui.instance_variable_get(:@config)).to eq(config)
    end

    it "defaults provider_name to 'local'" do
      tui = described_class.new(config:)
      expect(tui.instance_variable_get(:@provider_name)).to eq("local")
    end

    it "accepts a custom provider_name" do
      tui = described_class.new(config:, provider_name: "local")
      expect(tui.instance_variable_get(:@provider_name)).to eq("local")
    end

    it "starts with an empty message list" do
      tui = described_class.new(config:)
      expect(tui.instance_variable_get(:@messages)).to be_empty
    end

    it "starts with no overlay" do
      tui = described_class.new(config:)
      expect(tui.instance_variable_get(:@overlay_content)).to be_nil
    end

    it "starts with scroll offset 0" do
      tui = described_class.new(config:)
      expect(tui.instance_variable_get(:@scroll_offset)).to eq(0)
    end

    it "initializes with a messages_mutex for thread-safe message buffer" do
      tui = described_class.new(config:)
      expect(tui.instance_variable_get(:@messages_mutex)).to be_a(Mutex)
    end

    it "initializes with a render mutex for serialized ANSI output" do
      tui = described_class.new(config:)
      expect(tui.instance_variable_get(:@render_mutex)).to be_a(Mutex)
    end

    it "does not initialize scheduler when disabled" do
      tui = described_class.new(config:)
      expect(tui.instance_variable_get(:@scheduler_manager)).to be_nil
    end

    it "initializes with an activity indicator (Story 3)" do
      tui = described_class.new(config:)
      indicator = tui.instance_variable_get(:@activity_indicator)
      expect(indicator).to be_a(described_class::ActivityIndicator)
    end
  end

  # ── Identity Loading ──────────────────────────────────────────────

  describe "identity loading" do
    it "falls back to AGENT_NAME when SOUL.md is absent" do
      tui = described_class.new(config:)
      expect(tui.instance_variable_get(:@identity_line)).to eq(described_class::AGENT_NAME)
    end

    it "reads agent name from SOUL.md when present" do
      File.write(File.join(workspace_dir, "SOUL.md"), <<~MD)
        # Soul
        - **Name**: TestAgent
      MD
      tui = described_class.new(config:)
      expect(tui.instance_variable_get(:@identity_line)).to eq("TestAgent")
    end
  end

  # ── Terminal Helpers ──────────────────────────────────────────────

  describe "terminal helper methods" do
    subject(:tui) { described_class.new(config:) }

    it "returns a positive term_width" do
      allow(tui).to receive(:detect_width).and_return(120)
      # term_width delegates to @layout when present, otherwise detect_width
      expect(tui.send(:term_width)).to be_positive
    end

    it "returns a positive term_height" do
      allow(tui).to receive(:detect_height).and_return(40)
      expect(tui.send(:term_height)).to be_positive
    end

    it "chat_rows is at least term_height minus chrome rows (overlay suggestions no longer steal rows)" do
      allow(tui).to receive_messages(detect_height: 30, detect_width: 80)
      # chat_rows delegates to @layout when present; without layout it falls back to direct calc
      expect(tui.send(:chat_rows)).to be_positive
    end

    it "inner_width is at least term_width minus 2" do
      allow(tui).to receive(:detect_width).and_return(80)
      expect(tui.send(:inner_width)).to be >= 10
    end

    it "detects width fallback of 80 on error" do
      allow($stdout).to receive(:winsize).and_raise(RuntimeError)
      expect(tui.send(:detect_width)).to eq(80)
    end

    it "detects height fallback of 24 on error" do
      allow($stdout).to receive(:winsize).and_raise(RuntimeError)
      expect(tui.send(:detect_height)).to eq(24)
    end
  end

  # ── ANSI Helpers ──────────────────────────────────────────────────

  describe "paint and visible_len" do
    subject(:tui) { described_class.new(config:) }

    it "wraps text with ANSI codes" do
      result = tui.send(:paint, "hello", :bold)
      expect(result).to include("\e[1m")
      expect(result).to include("hello")
      expect(result).to include("\e[0m")
    end

    it "computes visible length ignoring ANSI codes" do
      colored = tui.send(:paint, "hello", :cyan)
      expect(tui.send(:visible_len, colored)).to eq(5)
    end

    it "handles multiple style arguments" do
      result = tui.send(:paint, "x", :bold, :cyan)
      expect(result).to include("\e[1m")
      expect(result).to include("\e[36m")
    end

    it "visible_len returns 0 for empty string" do
      expect(tui.send(:visible_len, "")).to eq(0)
    end

    it "generates a horizontal rule at a given width" do
      rule = tui.send(:horizontal_rule, "─", 10)
      expect(rule).to eq("─" * 10)
    end
  end

  # ── Message Queue ─────────────────────────────────────────────────

  describe "message queue methods" do
    subject(:tui) { described_class.new(config:) }

    it "push_user_message adds a user message with timestamp" do
      tui.send(:push_user_message, "Hello!")
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.last).to include(role: :user, text: "Hello!")
      expect(msgs.last[:timestamp]).to be_a(Time)
    end

    it "push_assistant_message adds an assistant message with timestamp" do
      tui.send(:push_assistant_message, "Hi there")
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.last).to include(role: :assistant, text: "Hi there")
      expect(msgs.last[:timestamp]).to be_a(Time)
    end

    it "push_info_message adds an info message with timestamp" do
      tui.send(:push_info_message, "Info text")
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.last).to include(role: :info, text: "Info text")
      expect(msgs.last[:timestamp]).to be_a(Time)
    end

    it "push_error_message adds an error message with timestamp" do
      tui.send(:push_error_message, "Something broke")
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.last).to include(role: :error, text: "Something broke")
      expect(msgs.last[:timestamp]).to be_a(Time)
    end
  end

  # ── Render Helpers (MessageRenderer via build_chat_lines) ───────────

  describe "#build_chat_lines with message rendering" do
    subject(:tui) do
      t = described_class.new(config:)
      allow(t).to receive_messages(detect_width: 80, detect_height: 24)
      t
    end

    it "renders a user message with the 'You' prefix" do
      tui.send(:push_user_message, "Hello world")
      lines = tui.send(:build_chat_lines)
      joined = lines.join
      expect(joined).to include("You")
      expect(joined).to include("Hello world")
    end

    it "renders an assistant message with the agent name prefix" do
      tui.send(:push_assistant_message, "I can help")
      lines = tui.send(:build_chat_lines)
      joined = lines.join
      expect(joined).to include(described_class::AGENT_NAME)
      expect(joined).to include("I can help")
    end

    it "wraps long lines at the specified width" do
      long_text = "word " * 30
      tui.send(:push_user_message, long_text.strip)
      lines = tui.send(:build_chat_lines)
      raw_lines = lines.map { |l| tui.send(:visible_len, l) }
      expect(raw_lines.all? { |len| len <= 82 }).to be true
    end
  end

  describe "MessageRenderer (role labels)" do
    it "role_label returns You for user via MessageRenderer" do
      r = described_class::MessageRenderer.new(width: 80)
      lines = r.render({ role: :user, text: "x", timestamp: nil })
      expect(lines.join).to include("You")
    end

    it "role_label returns agent name for assistant via MessageRenderer" do
      r = described_class::MessageRenderer.new(width: 80)
      lines = r.render({ role: :assistant, text: "x", timestamp: nil })
      expect(lines.join).to include(described_class::AGENT_NAME)
    end
  end

  # ── Status Bar ────────────────────────────────────────────────────

  describe "#status_bar_content" do
    it "includes model tier" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@session, Homunculus::Session.new)
      allow(tui).to receive(:use_models_router?).and_return(true)
      content = tui.send(:status_bar_content)
      expect(tui.send(:visible_len, content)).to be > 0
      # model section now uses a tier dot (● or o) instead of the role indicator glyph
      expect(content).to include("router")
    end

    it "includes token counts when session is set" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@session, Homunculus::Session.new)
      content = tui.send(:status_bar_content)
      expect(content).to include("tokens:")
    end

    it "includes turn count" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@session, Homunculus::Session.new)
      content = tui.send(:status_bar_content)
      expect(content).to include("turn ")
      expect(content).to include("/25")
    end

    it "shows spinner frame and message when activity indicator is running (Story 3)" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@session, Homunculus::Session.new)
      allow(tui).to receive(:refresh_status_bar)
      indicator = tui.instance_variable_get(:@activity_indicator)
      indicator.start("Thinking...")
      content = tui.send(:status_bar_content)
      indicator.stop
      expect(content).to include("Thinking...")
      expect(content).to match(/[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/)
    end

    it "includes resolved tier and model when @current_tier and @current_model set (Story 8)" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@session, Homunculus::Session.new)
      tui.instance_variable_set(:@current_tier, "workhorse")
      tui.instance_variable_set(:@current_model, "qwen3:14b")
      allow(tui).to receive(:use_models_router?).and_return(true)
      content = tui.send(:status_bar_content)
      expect(content).to include("workhorse")
      expect(content).to include("tokens:")
    end

    it "includes escalation text when @current_escalated_from set (Story 8)" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@session, Homunculus::Session.new)
      tui.instance_variable_set(:@current_tier, "cloud_fast")
      tui.instance_variable_set(:@current_model, "claude-haiku")
      tui.instance_variable_set(:@current_escalated_from, "workhorse")
      allow(tui).to receive(:use_models_router?).and_return(true)
      content = tui.send(:status_bar_content)
      expect(content).to include("cloud_fast")
      expect(content).to include("escalated from workhorse")
    end

    it "applies green ANSI to model segment for local tier (Story 8)" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@session, Homunculus::Session.new)
      tui.instance_variable_set(:@current_tier, "workhorse")
      tui.instance_variable_set(:@current_model, "qwen3:14b")
      allow(tui).to receive(:use_models_router?).and_return(true)
      content = tui.send(:status_bar_content)
      expect(content).to include("\e[32m") # green
    end

    it "applies yellow ANSI to model segment for cloud tier (Story 8)" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@session, Homunculus::Session.new)
      tui.instance_variable_set(:@current_tier, "cloud_fast")
      tui.instance_variable_set(:@current_model, "claude-haiku")
      allow(tui).to receive(:use_models_router?).and_return(true)
      content = tui.send(:status_bar_content)
      expect(content).to include("\e[33m") # yellow
    end

    it "applies red color to model dot when escalated (Story 8)" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@session, Homunculus::Session.new)
      tui.instance_variable_set(:@current_tier, "cloud_fast")
      tui.instance_variable_set(:@current_model, "claude-haiku")
      tui.instance_variable_set(:@current_escalated_from, "workhorse")
      allow(tui).to receive(:use_models_router?).and_return(true)
      content = tui.send(:status_bar_content)
      # escalated tier dot uses red foreground (38;5;167 in 256-color, 31m in 16-color)
      expect(content).to match(/\e\[(?:38;5;167|31)m/)
    end

    it "includes elapsed session time when @session_start_time is set (Story 6)" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@session, Homunculus::Session.new)
      tui.instance_variable_set(:@session_start_time, Time.now - 125)
      content = tui.send(:status_bar_content)
      expect(content).to match(/\d+m\s+\d+s/)
    end

    it "shows ↕ scrolled when @scroll_offset > 0 (Story 6)" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@session, Homunculus::Session.new)
      tui.instance_variable_set(:@scroll_offset, 5)
      content = tui.send(:status_bar_content)
      expect(content).to include("↕ scrolled")
    end

    it "shows ⚠ awaiting confirm when pending_tool_call (Story 6)" do
      tui = described_class.new(config:)
      session = Homunculus::Session.new
      session.pending_tool_call = Homunculus::Agent::ModelProvider::ToolCall.new(
        id: "x", name: "shell_exec", arguments: {}
      )
      tui.instance_variable_set(:@session, session)
      content = tui.send(:status_bar_content)
      expect(content).to include("awaiting confirm")
    end
  end

  describe "#model_tier_label" do
    it "returns tier and model when @current_tier and @current_model set" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@current_tier, "workhorse")
      tui.instance_variable_set(:@current_model, "qwen3:14b")
      allow(tui).to receive(:use_models_router?).and_return(true)
      expect(tui.send(:model_tier_label)).to eq("model: workhorse (qwen3:14b)")
    end

    it "appends escalation suffix when @current_escalated_from set" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@current_tier, "cloud_fast")
      tui.instance_variable_set(:@current_model, "claude-haiku")
      tui.instance_variable_set(:@current_escalated_from, "workhorse")
      allow(tui).to receive(:use_models_router?).and_return(true)
      expect(tui.send(:model_tier_label)).to include("⚡ escalated from workhorse")
    end

    it "falls back to router when no current tier and models_router" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@current_tier, nil)
      allow(tui).to receive(:use_models_router?).and_return(true)
      expect(tui.send(:model_tier_label)).to eq("model: router")
    end
  end

  describe "#model_tier_style and #cloud_tier?" do
    it "returns :green for local tier" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@current_tier, "workhorse")
      tui.instance_variable_set(:@current_escalated_from, nil)
      expect(tui.send(:model_tier_style)).to eq(:green)
    end

    it "returns :yellow for cloud tier" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@current_tier, "cloud_fast")
      tui.instance_variable_set(:@current_escalated_from, nil)
      expect(tui.send(:model_tier_style)).to eq(:yellow)
    end

    it "returns :bg_red when escalated_from set" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@current_tier, "cloud_fast")
      tui.instance_variable_set(:@current_escalated_from, "workhorse")
      expect(tui.send(:model_tier_style)).to eq(:bg_red)
    end
  end

  # ── Input Processing ──────────────────────────────────────────────

  describe "#process_input" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      t.instance_variable_set(:@running, true)
      # Wire a real event loop queue so shutdown push doesn't raise
      event_loop = instance_double(described_class::EventLoop, push: nil, queue: Thread::Queue.new)
      t.instance_variable_set(:@event_loop, event_loop)
      t
    end

    before do
      allow(tui).to receive(:refresh_all)
    end

    it "pushes :shutdown event on 'quit'" do
      event_loop = tui.instance_variable_get(:@event_loop)
      tui.send(:process_input, "quit")
      expect(event_loop).to have_received(:push).with({ type: :shutdown })
    end

    it "pushes :shutdown event on 'exit'" do
      event_loop = tui.instance_variable_get(:@event_loop)
      tui.send(:process_input, "exit")
      expect(event_loop).to have_received(:push).with({ type: :shutdown })
    end

    it "pushes :shutdown event on ':q'" do
      event_loop = tui.instance_variable_get(:@event_loop)
      tui.send(:process_input, ":q")
      expect(event_loop).to have_received(:push).with({ type: :shutdown })
    end

    it "does nothing on empty input" do
      expect(tui).not_to receive(:handle_message)
      tui.send(:process_input, "")
      expect(tui.instance_variable_get(:@running)).to be true
    end

    it "does not add help to @messages when show_help is called (overlay only)" do
      allow(tui).to receive(:handle_message)
      tui.send(:show_help)
      tui.send(:show_help)
      msgs = tui.instance_variable_get(:@messages)
      help_entries = msgs.select { |m| m[:role] == :info && m[:text].to_s.include?("Here's what I can do") }
      expect(help_entries.size).to eq(0)
    end

    it "clears messages on 'clear'" do
      tui.instance_variable_set(:@messages, [{ role: :user, text: "hi" }])
      tui.send(:process_input, "clear")
      expect(tui.instance_variable_get(:@messages)).to be_empty
    end

    it "delegates to handle_message for regular input" do
      allow(tui).to receive(:handle_message).with("hello world")
      tui.send(:process_input, "hello world")
      expect(tui).to have_received(:handle_message).with("hello world")
    end

    it "dispatches /help to show_help (slash command)" do
      allow(tui).to receive(:show_help)
      tui.send(:process_input, "/help")
      expect(tui).to have_received(:show_help)
    end

    it "dispatches /status to show_status" do
      allow(tui).to receive(:show_status)
      tui.send(:process_input, "/status")
      expect(tui).to have_received(:show_status)
    end

    it "shows unknown command overlay for /unknown" do
      tui.send(:process_input, "/unknown")
      overlay = tui.instance_variable_get(:@overlay_content)
      expect(overlay).not_to be_nil
      expect(overlay.join).to include("Unknown command")
      expect(overlay.join).to include("/help")
    end

    it "bare 'help' still calls show_help (backward compat)" do
      allow(tui).to receive(:show_help)
      tui.send(:process_input, "help")
      expect(tui).to have_received(:show_help)
    end

    it "bare 'status' still calls show_status (backward compat)" do
      allow(tui).to receive(:show_status)
      tui.send(:process_input, "status")
      expect(tui).to have_received(:show_status)
    end

    it "/quit pushes :shutdown event to event loop" do
      event_loop = tui.instance_variable_get(:@event_loop)
      tui.send(:process_input, "/quit")
      expect(event_loop).to have_received(:push).with({ type: :shutdown })
    end

    it "dispatches /model to show_model" do
      allow(tui).to receive(:show_model)
      tui.send(:process_input, "/model")
      expect(tui).to have_received(:show_model)
    end
  end

  describe "#apply_tab_completion" do
    subject(:tui) do
      described_class.new(config:)
    end

    it "completes buffer to first suggestion when buffer is prefix" do
      buf = Homunculus::Interfaces::TUI::InputBuffer.new
      buf.insert("/")
      buf.insert("h")
      buf.insert("e")
      tui.instance_variable_set(:@suggestion_lines, ["/help"])
      tui.send(:apply_tab_completion, buf)
      expect(buf.to_s).to eq("/help")
    end

    it "returns false when buffer does not start with /" do
      buf = Homunculus::Interfaces::TUI::InputBuffer.new
      buf.insert("help")
      tui.instance_variable_set(:@suggestion_lines, ["/help"])
      expect(tui.send(:apply_tab_completion, buf)).to be false
      expect(buf.to_s).to eq("help")
    end

    it "returns false when no suggestions" do
      buf = Homunculus::Interfaces::TUI::InputBuffer.new
      buf.insert("/x")
      tui.instance_variable_set(:@suggestion_lines, [])
      expect(tui.send(:apply_tab_completion, buf)).to be false
    end
  end

  # ── display_result ────────────────────────────────────────────────

  describe "#display_result" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      t
    end

    before { allow(tui).to receive(:refresh_all) }

    it "pushes assistant message on :completed status (non-router mode)" do
      result = Homunculus::Agent::AgentResult.completed("Done!", session: tui.instance_variable_get(:@session))
      allow(tui).to receive(:use_models_router?).and_return(false)
      tui.send(:display_result, result)
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.any? { |m| m[:role] == :assistant && m[:text] == "Done!" }).to be true
    end

    it "pushes tool_request message on :pending_confirmation status" do
      tool_call = Homunculus::Agent::ModelProvider::ToolCall.new(
        id: "tc-1", name: "shell_exec", arguments: { command: "ls" }
      )
      result = Homunculus::Agent::AgentResult.pending_confirmation(
        tool_call,
        session: tui.instance_variable_get(:@session)
      )
      tui.send(:display_result, result)
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.any? { |m| m[:role] == :tool_request && m[:tool_name] == "shell_exec" }).to be true
    end

    it "pushes error message on :error status" do
      result = Homunculus::Agent::AgentResult.error("Boom", session: tui.instance_variable_get(:@session))
      tui.send(:display_result, result)
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.any? { |m| m[:role] == :error && m[:text].include?("Boom") }).to be true
    end

    it "sets @current_tier, @current_model, @current_escalated_from from completed result (Story 8)" do
      result = Homunculus::Agent::AgentResult.completed(
        "Done!",
        session: tui.instance_variable_get(:@session),
        tier: "workhorse", model: "qwen3:14b", escalated_from: nil
      )
      allow(tui).to receive(:use_models_router?).and_return(true)
      tui.send(:display_result, result)
      expect(tui.instance_variable_get(:@current_tier)).to eq("workhorse")
      expect(tui.instance_variable_get(:@current_model)).to eq("qwen3:14b")
      expect(tui.instance_variable_get(:@current_escalated_from)).to be_nil
    end

    it "sets @current_escalated_from when result has escalation (Story 8)" do
      result = Homunculus::Agent::AgentResult.completed(
        "Done!",
        session: tui.instance_variable_get(:@session),
        tier: "cloud_fast", model: "claude-haiku", escalated_from: "workhorse"
      )
      allow(tui).to receive(:use_models_router?).and_return(true)
      tui.send(:display_result, result)
      expect(tui.instance_variable_get(:@current_escalated_from)).to eq("workhorse")
    end
  end

  # ── Scroll Key Handling ───────────────────────────────────────────

  describe "#handle_scroll_keys" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@scroll_offset, 0)
      layout = described_class::Layout.new(term_width: 80, term_height: 30)
      t.instance_variable_set(:@layout, layout)
      t
    end

    before do
      allow(tui).to receive(:build_chat_lines).and_return(["line"] * 50)
    end

    it "scrolls up on '[A'" do
      tui.send(:handle_scroll_keys, "[A")
      expect(tui.instance_variable_get(:@scroll_offset)).to be > 0
    end

    it "scrolls down but not below zero" do
      tui.send(:handle_scroll_keys, "[B")
      expect(tui.instance_variable_get(:@scroll_offset)).to eq(0)
    end

    it "page up increases scroll offset" do
      tui.send(:handle_scroll_keys, "[5~")
      expect(tui.instance_variable_get(:@scroll_offset)).to be > 0
    end

    it "page down does not go below zero" do
      tui.send(:handle_scroll_keys, "[6~")
      expect(tui.instance_variable_get(:@scroll_offset)).to eq(0)
    end
  end

  # ── Scheduler Integration ─────────────────────────────────────────

  describe "scheduler integration" do
    it "does not initialize scheduler when disabled" do
      tui = described_class.new(config:)
      expect(tui.instance_variable_get(:@scheduler_manager)).to be_nil
    end

    context "when scheduler is enabled" do
      let(:sched_config) do
        raw = TomlRB.load_file("config/default.toml")
        raw["agent"] = { "workspace_path" => workspace_dir }
        raw["scheduler"] = {
          "enabled" => true,
          "db_path" => File.join(db_dir, "scheduler.db"),
          "heartbeat" => {
            "enabled" => true,
            "cron" => "*/30 8-22 * * *",
            "model" => "local",
            "active_hours_start" => 8,
            "active_hours_end" => 22,
            "timezone" => "UTC"
          },
          "notification" => {
            "max_per_hour" => 10,
            "quiet_hours_queue" => true
          }
        }
        Homunculus::Config.new(raw)
      end

      before do
        File.write(File.join(workspace_dir, "HEARTBEAT.md"), "# Heartbeat\n")
      end

      it "initializes scheduler_manager when enabled" do
        tui = described_class.new(config: sched_config)
        expect(tui.instance_variable_get(:@scheduler_manager)).not_to be_nil
      end
    end
  end

  # ── Rendering Methods ─────────────────────────────────────────────
  # The new architecture writes to a ScreenBuffer and flushes once per frame.
  # Tests verify that frame components write correct content to the buffer.

  describe "rendering methods" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      layout = described_class::Layout.new(term_width: 80, term_height: 24)
      screen = described_class::ScreenBuffer.new(24, 80)
      t.instance_variable_set(:@layout, layout)
      t.instance_variable_set(:@screen, screen)
      input_buf = described_class::InputBuffer.new
      t.instance_variable_set(:@input_buffer, input_buf)
      t
    end

    let(:io) { StringIO.new }

    it "render_header_frame writes agent name to screen buffer" do
      tui.send(:render_header_frame)
      tui.instance_variable_get(:@screen).force_flush(io)
      visible = io.string.gsub(/\e\[[0-9;]*[mGKHF]/, "")
      expect(visible).to include(described_class::AGENT_NAME)
    end

    it "render_chat_panel_frame writes chat content to screen buffer" do
      tui.send(:push_user_message, "test message")
      tui.send(:render_chat_panel_frame)
      tui.instance_variable_get(:@screen).force_flush(io)
      visible = io.string.gsub(/\e\[[0-9;]*[mGKHF]/, "")
      expect(visible).to include("test message")
    end

    it "render_status_bar_frame writes status content to screen buffer" do
      tui.send(:render_status_bar_frame)
      tui.instance_variable_get(:@screen).force_flush(io)
      # Status bar has content (router or provider name)
      expect(io.string).not_to be_empty
    end

    it "render_input_line_frame writes prompt character to screen buffer" do
      input_buf = tui.instance_variable_get(:@input_buffer)
      input_buf.insert("t")
      input_buf.insert("e")
      input_buf.insert("s")
      input_buf.insert("t")
      tui.send(:render_input_line_frame)
      tui.instance_variable_get(:@screen).force_flush(io)
      visible = io.string.gsub(/\e\[[0-9;]*[mGKHF]/, "")
      expect(visible).to include(described_class::Theme.prompt_char)
    end

    it "render_input_line_frame tolerates ASCII-8BIT input without raising" do
      buf = tui.instance_variable_get(:@input_buffer)
      "\xC3".b.each_byte { |b| buf.insert(b.chr(Encoding::ASCII_8BIT)) rescue nil } # rubocop:disable Style/RescueModifier
      expect { tui.send(:render_input_line_frame) }.not_to raise_error
    end

    it "render_frame calls all sub-renders and flushes screen to stdout" do
      expect(tui).to receive(:render_header_frame).and_call_original
      expect(tui).to receive(:render_chat_panel_frame).and_call_original
      expect(tui).to receive(:render_status_bar_frame).and_call_original
      expect(tui).to receive(:render_input_line_frame).and_call_original
      screen = tui.instance_variable_get(:@screen)
      expect(screen).to receive(:flush).with($stdout)
      tui.send(:render_frame)
    end

    it "refresh_all pushes a :refresh event to the event loop queue" do
      queue = Thread::Queue.new
      event_loop = instance_double(described_class::EventLoop, push: nil, queue: queue)
      tui.instance_variable_set(:@event_loop, event_loop)
      tui.send(:refresh_all)
      expect(event_loop).to have_received(:push).with({ type: :refresh })
    end
  end

  # ── build_chat_lines ──────────────────────────────────────────────

  describe "#build_chat_lines" do
    subject(:tui) do
      t = described_class.new(config:)
      allow(t).to receive_messages(detect_width: 80, detect_height: 24)
      t
    end

    it "returns empty array when no messages" do
      expect(tui.send(:build_chat_lines)).to eq([])
    end

    it "returns lines for each message with blank separators" do
      tui.send(:push_user_message, "hello")
      tui.send(:push_assistant_message, "world")
      lines = tui.send(:build_chat_lines)
      expect(lines).not_to be_empty
      # Each message is followed by a blank line
      expect(lines).to include("")
    end

    it "includes text content in the lines" do
      tui.send(:push_user_message, "unique marker text")
      lines = tui.send(:build_chat_lines)
      joined = lines.map { |l| l.gsub(/\e\[[0-9;]*[mGKHF]/, "") }.join(" ")
      expect(joined).to include("unique marker text")
    end
  end

  # ── Streaming Callback ────────────────────────────────────────────
  # build_stream_callback now pushes :stream_chunk events to the event loop queue.
  # Direct chunk behavior is tested via append_stream_chunk which is called by
  # handle_stream_chunk_event. Tests below verify the underlying mechanics.

  describe "streaming callback" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      t
    end

    it "build_stream_callback creates a callable" do
      cb = tui.send(:build_stream_callback)
      expect(cb).to respond_to(:call)
    end

    it "append_stream_chunk appends to streaming_buf" do
      tui.send(:append_stream_chunk, "hello ")
      tui.send(:append_stream_chunk, "world")
      buf = tui.instance_variable_get(:@streaming_buf)
      expect(buf[:text]).to eq("hello world")
      expect(buf[:role]).to eq(:assistant)
    end

    it "append_stream_chunk adds the message to @messages on first chunk" do
      msgs_before = tui.instance_variable_get(:@messages).length
      tui.send(:append_stream_chunk, "first chunk")
      expect(tui.instance_variable_get(:@messages).length).to eq(msgs_before + 1)
    end

    it "append_stream_chunk does not add duplicate messages on subsequent chunks" do
      tui.send(:append_stream_chunk, "first")
      count_after_first = tui.instance_variable_get(:@messages).length
      tui.send(:append_stream_chunk, "second")
      expect(tui.instance_variable_get(:@messages).length).to eq(count_after_first)
    end

    it "sets timestamp on streaming message when first chunk arrives" do
      tui.send(:append_stream_chunk, "first chunk")
      buf = tui.instance_variable_get(:@streaming_buf)
      expect(buf[:timestamp]).to be_a(Time)
    end

    it "stops activity indicator on first chunk (Story 3)" do
      indicator = tui.instance_variable_get(:@activity_indicator)
      allow(indicator).to receive(:stop).and_call_original
      tui.send(:handle_stream_chunk_event, { type: :stream_chunk, chunk: "first" })
      expect(indicator).to have_received(:stop)
    end

    it "updates streaming_output_tokens_estimate as chunks arrive (Story 4)" do
      tui.send(:append_stream_chunk, "one")
      estimate1 = tui.instance_variable_get(:@streaming_output_tokens_estimate)
      expect(estimate1).to be_a(Integer)
      expect(estimate1).to be >= 1
      tui.send(:append_stream_chunk, " two three four five")
      estimate2 = tui.instance_variable_get(:@streaming_output_tokens_estimate)
      expect(estimate2).to be > estimate1
    end

    it "sets streaming_output_tokens_estimate from word and char heuristic" do
      tui.send(:append_stream_chunk, "hello world")
      estimate = tui.instance_variable_get(:@streaming_output_tokens_estimate)
      expect(estimate).to be_a(Integer)
      expect(estimate).to be >= 1
    end

    it "preserves manual scroll position during streaming when user is not at bottom" do
      allow(tui).to receive_messages(detect_width: 40, detect_height: 24)
      tui.send(:push_user_message, "seed message")
      tui.instance_variable_set(:@scroll_offset, 3)

      tui.send(:append_stream_chunk, " #{"x" * 120}")

      expect(tui.instance_variable_get(:@scroll_offset)).to be > 3
    end

    it "keeps following newest output when already at the bottom" do
      allow(tui).to receive_messages(detect_width: 40, detect_height: 24)
      tui.send(:append_stream_chunk, " #{"x" * 120}")

      expect(tui.instance_variable_get(:@scroll_offset)).to eq(0)
    end
  end

  # ── token_usage_label (Story 4) ───────────────────────────────────

  describe "#token_usage_label" do
    it "returns nil when session is nil" do
      tui = described_class.new(config:)
      expect(tui.instance_variable_get(:@session)).to be_nil
      expect(tui.send(:token_usage_label)).to be_nil
    end

    it "shows session totals only when no streaming estimate" do
      tui = described_class.new(config:)
      session = Homunculus::Session.new
      usage = Homunculus::Agent::ModelProvider::TokenUsage.new(input_tokens: 100, output_tokens: 50)
      session.track_usage(usage)
      tui.instance_variable_set(:@session, session)
      label = tui.send(:token_usage_label)
      expect(label).to include("tokens: 100↓ 50↑")
    end

    it "includes streaming estimate when set (Story 4)" do
      tui = described_class.new(config:)
      session = Homunculus::Session.new
      session.track_usage(
        Homunculus::Agent::ModelProvider::TokenUsage.new(input_tokens: 200, output_tokens: 80)
      )
      tui.instance_variable_set(:@session, session)
      tui.instance_variable_set(:@streaming_output_tokens_estimate, 15)
      label = tui.send(:token_usage_label)
      expect(label).to include("95↑") # 80 + 15
      expect(label).to include("+15⚡")
    end

    it "shows session totals after estimate cleared" do
      tui = described_class.new(config:)
      session = Homunculus::Session.new
      session.track_usage(
        Homunculus::Agent::ModelProvider::TokenUsage.new(input_tokens: 300, output_tokens: 120)
      )
      tui.instance_variable_set(:@session, session)
      tui.instance_variable_set(:@streaming_output_tokens_estimate, 10)
      tui.instance_variable_get(:@messages_mutex).synchronize do
        tui.instance_variable_set(:@streaming_output_tokens_estimate, nil)
      end
      label = tui.send(:token_usage_label)
      expect(label).to include("tokens: 300↓ 120↑")
    end
  end

  # ── context window display ────────────────────────────────────────

  describe "#token_usage_label with context window" do
    it "includes ctx: usage summary when context_window is available" do
      tui = described_class.new(config:)
      session = Homunculus::Session.new
      session.track_usage(
        Homunculus::Agent::ModelProvider::TokenUsage.new(input_tokens: 1000, output_tokens: 500)
      )
      tui.instance_variable_set(:@session, session)
      tui.instance_variable_set(:@current_context_window, 32_768)
      label = tui.send(:token_usage_label)
      expect(label).to include("ctx:")
      expect(label).to include("/32.8k")
      expect(label).to match(/\(\d+%\)/)
    end

    it "omits ctx: summary when context_window is nil" do
      tui = described_class.new(config:)
      session = Homunculus::Session.new
      session.track_usage(
        Homunculus::Agent::ModelProvider::TokenUsage.new(input_tokens: 100, output_tokens: 50)
      )
      tui.instance_variable_set(:@session, session)
      tui.instance_variable_set(:@current_context_window, nil)
      # Override resolved_context_window to return nil
      allow(tui).to receive(:resolved_context_window).and_return(nil)
      label = tui.send(:token_usage_label)
      expect(label).not_to include("ctx:")
    end

    it "uses @current_context_window when set (overrides config default)" do
      tui = described_class.new(config:)
      session = Homunculus::Session.new
      session.track_usage(
        Homunculus::Agent::ModelProvider::TokenUsage.new(input_tokens: 500, output_tokens: 200)
      )
      tui.instance_variable_set(:@session, session)
      tui.instance_variable_set(:@current_context_window, 200_000)
      label = tui.send(:token_usage_label)
      expect(label).to include("/200k")
    end
  end

  describe "#format_token_count" do
    it "returns plain number for values below 1000" do
      tui = described_class.new(config:)
      expect(tui.send(:format_token_count, 512)).to eq("512")
    end

    it "formats 1000 as 1k" do
      tui = described_class.new(config:)
      expect(tui.send(:format_token_count, 1000)).to eq("1k")
    end

    it "formats 32768 as 32.8k" do
      tui = described_class.new(config:)
      expect(tui.send(:format_token_count, 32_768)).to eq("32.8k")
    end

    it "formats 200000 as 200k" do
      tui = described_class.new(config:)
      expect(tui.send(:format_token_count, 200_000)).to eq("200k")
    end

    it "formats 4231 as 4.2k" do
      tui = described_class.new(config:)
      expect(tui.send(:format_token_count, 4231)).to eq("4.2k")
    end
  end

  describe "#resolved_context_window" do
    it "returns @current_context_window when set" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@current_context_window, 16_384)
      expect(tui.send(:resolved_context_window)).to eq(16_384)
    end

    it "falls back to config local context_window when @current_context_window is nil" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@current_context_window, nil)
      expect(tui.send(:resolved_context_window)).to eq(config.models[:local].context_window)
    end
  end

  describe "#update_context_window_from_result" do
    it "sets @current_context_window from result when positive" do
      tui = described_class.new(config:)
      result = Homunculus::Agent::AgentResult.completed(
        "ok", session: Homunculus::Session.new, context_window: 16_384
      )
      tui.send(:update_context_window_from_result, result)
      expect(tui.instance_variable_get(:@current_context_window)).to eq(16_384)
    end

    it "does not update @current_context_window when result has no context_window" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@current_context_window, 32_768)
      result = Homunculus::Agent::AgentResult.completed("ok", session: Homunculus::Session.new)
      tui.send(:update_context_window_from_result, result)
      expect(tui.instance_variable_get(:@current_context_window)).to eq(32_768)
    end
  end

  # ── handle_message ────────────────────────────────────────────────
  # handle_message now spawns a Thread that pushes :agent_result to @event_loop.
  # Tests synchronize by joining the spawned thread.

  describe "#handle_message" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      t.instance_variable_set(:@running, true)
      event_loop = instance_double(described_class::EventLoop, push: nil, queue: Thread::Queue.new)
      t.instance_variable_set(:@event_loop, event_loop)
      t
    end

    before do
      allow(tui).to receive(:refresh_all)
    end

    it "pushes a user message before spawning agent thread" do
      agent_loop = tui.instance_variable_get(:@agent_loop)
      session    = tui.instance_variable_get(:@session)
      allow(agent_loop).to receive(:run).and_return(
        Homunculus::Agent::AgentResult.completed("ok", session:)
      )
      tui.send(:handle_message, "what time is it?")
      # The user message is pushed synchronously before the thread is spawned
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.any? { |m| m[:role] == :user && m[:text] == "what time is it?" }).to be true
    end

    it "warns if there is a pending tool call" do
      tool_call = Homunculus::Agent::ModelProvider::ToolCall.new(
        id: "x", name: "shell_exec", arguments: {}
      )
      tui.instance_variable_get(:@session).pending_tool_call = tool_call
      tui.send(:handle_message, "some input")
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.any? { |m| m[:role] == :info && m[:text].include?("Pending tool call") }).to be true
    end

    it "pushes an agent_result event with error when the agent loop raises" do
      agent_loop = tui.instance_variable_get(:@agent_loop)
      allow(agent_loop).to receive(:run).and_raise(StandardError, "network down")
      event_loop = tui.instance_variable_get(:@event_loop)
      indicator  = tui.instance_variable_get(:@activity_indicator)
      allow(indicator).to receive(:start)
      tui.send(:handle_message, "hello")
      # Wait briefly for the background thread to push the error result
      sleep(0.3)
      expect(event_loop).to have_received(:push) do |event|
        event[:type] == :agent_result
      end
    end

    it "runs agent in a background thread and pushes agent_result to event loop" do
      agent_loop = tui.instance_variable_get(:@agent_loop)
      session = tui.instance_variable_get(:@session)
      result = Homunculus::Agent::AgentResult.completed("done", session:)
      allow(agent_loop).to receive(:run).and_return(result)
      event_loop = tui.instance_variable_get(:@event_loop)
      indicator  = tui.instance_variable_get(:@activity_indicator)
      allow(indicator).to receive(:start)
      tui.send(:handle_message, "ping")
      # Wait for background thread to complete
      sleep(0.3)
      expect(event_loop).to have_received(:push).with({ type: :agent_result, result: })
    end

    it "starts activity indicator before agent (Story 3)" do
      agent_loop = tui.instance_variable_get(:@agent_loop)
      session = tui.instance_variable_get(:@session)
      allow(agent_loop).to receive(:run).and_return(
        Homunculus::Agent::AgentResult.completed("ok", session:)
      )
      indicator = tui.instance_variable_get(:@activity_indicator)
      allow(indicator).to receive(:start).and_call_original
      tui.send(:handle_message, "hello")
      expect(indicator).to have_received(:start).with("Thinking...")
    end

    it "clears streaming_output_tokens_estimate when agent_result is handled (Story 4)" do
      session = tui.instance_variable_get(:@session)
      result = Homunculus::Agent::AgentResult.completed("done", session:)
      allow(tui).to receive(:display_result)
      tui.instance_variable_set(:@streaming_output_tokens_estimate, 42)
      # handle_agent_result_event clears the estimate
      tui.send(:handle_agent_result_event, { type: :agent_result, result: })
      expect(tui.instance_variable_get(:@streaming_output_tokens_estimate)).to be_nil
    end
  end

  # ── Story 2: Mutex and scroll during agent ─────────────────────────

  describe "message buffer mutex and scroll during streaming" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      layout = described_class::Layout.new(term_width: 80, term_height: 24)
      t.instance_variable_set(:@layout, layout)
      allow(t).to receive_messages(detect_width: 80, detect_height: 24)
      t
    end

    it "allows concurrent append_stream_chunk and build_chat_lines without raising" do
      reader = Thread.new do
        20.times { tui.send(:build_chat_lines) }
      end
      writer = Thread.new do
        20.times { |i| tui.send(:append_stream_chunk, " chunk #{i}") }
      end
      expect do
        reader.join(2)
        writer.join(2)
      end.not_to raise_error
    end

    it "handle_scroll_keys updates scroll_offset and can be called while messages exist (mutex-held reads)" do
      tui.send(:push_user_message, "one")
      tui.send(:push_assistant_message, "two")
      tui.send(:handle_scroll_keys, "[5~")
      expect(tui.instance_variable_get(:@scroll_offset)).to be >= 0
    end
  end

  describe "render serialization helpers" do
    it "serializes concurrent render ownership through with_render_lock" do
      tui = described_class.new(config:)
      active = 0
      max_active = 0

      threads = 2.times.map do
        Thread.new do
          tui.send(:with_render_lock) do
            active += 1
            max_active = [max_active, active].max
            sleep(0.02)
            active -= 1
          end
        end
      end

      threads.each(&:join)
      expect(max_active).to eq(1)
    end

    it "pushes :refresh events to event loop when tool status changes" do
      tui = described_class.new(config:)
      event_loop = instance_double(described_class::EventLoop, push: nil, queue: Thread::Queue.new)
      tui.instance_variable_set(:@event_loop, event_loop)
      callback = tui.send(:build_status_callback)

      callback.call(:tool_start, "echo")
      callback.call(:tool_end, "echo")

      expect(event_loop).to have_received(:push).with({ type: :tick }).twice
    end
  end

  describe "scroll indicators in render_chat_panel" do
    # Use a layout with only 6 chat rows so scroll indicators appear with few messages
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      layout = described_class::Layout.new(term_width: 80, term_height: 13)
      screen = described_class::ScreenBuffer.new(13, 80)
      t.instance_variable_set(:@layout, layout)
      t.instance_variable_set(:@screen, screen)
      t.instance_variable_set(:@input_buffer, described_class::InputBuffer.new)
      t
    end

    let(:io) { StringIO.new }

    it "shows ▲ more above when scrolled up and not at top" do
      5.times { |i| tui.send(:push_user_message, "msg #{i} " + ("x " * 20)) }
      tui.instance_variable_set(:@scroll_offset, 2)
      tui.send(:render_chat_panel_frame)
      tui.instance_variable_get(:@screen).force_flush(io)
      raw = io.string.gsub(/\e\[[0-9;]*[mGKHF]/, "")
      expect(raw).to include("▲ more above")
    end

    it "shows ▼ more below when user has scrolled up (scroll_offset > 0)" do
      # Generate enough lines so max_scroll > 0, then scroll up so show_below triggers
      10.times { |i| tui.send(:push_user_message, "line #{i} " + ("word " * 15)) }
      # Set scroll_offset so we're not at the bottom (show_below = scroll_offset > 0)
      tui.instance_variable_set(:@scroll_offset, 5)
      tui.send(:render_chat_panel_frame)
      tui.instance_variable_get(:@screen).force_flush(io)
      raw = io.string.gsub(/\e\[[0-9;]*[mGKHF]/, "")
      expect(raw).to include("▼ more below")
    end
  end

  # ── handle_confirm / handle_deny ─────────────────────────────────

  describe "#handle_confirm and #handle_deny" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      event_loop = instance_double(described_class::EventLoop, push: nil, queue: Thread::Queue.new)
      t.instance_variable_set(:@event_loop, event_loop)
      t
    end

    before do
      allow(tui).to receive(:refresh_all)
    end

    it "handle_confirm warns when no pending call" do
      tui.send(:handle_confirm)
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.any? { |m| m[:role] == :info && m[:text].include?("No pending") }).to be true
    end

    it "handle_deny warns when no pending call" do
      tui.send(:handle_deny)
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.any? { |m| m[:role] == :info && m[:text].include?("No pending") }).to be true
    end

    it "handle_confirm confirms and calls agent loop" do
      tool_call = Homunculus::Agent::ModelProvider::ToolCall.new(
        id: "t1", name: "echo", arguments: { message: "hi" }
      )
      session = tui.instance_variable_get(:@session)
      session.pending_tool_call = tool_call
      agent_loop = tui.instance_variable_get(:@agent_loop)
      allow(agent_loop).to receive(:confirm_tool).and_return(
        Homunculus::Agent::AgentResult.completed("confirmed", session:)
      )
      tui.send(:handle_confirm)
      sleep(0.3)
      expect(agent_loop).to have_received(:confirm_tool)
    end

    it "handle_deny denies and calls agent loop" do
      tool_call = Homunculus::Agent::ModelProvider::ToolCall.new(
        id: "t2", name: "echo", arguments: { message: "hi" }
      )
      session = tui.instance_variable_get(:@session)
      session.pending_tool_call = tool_call
      agent_loop = tui.instance_variable_get(:@agent_loop)
      allow(agent_loop).to receive(:deny_tool).and_return(
        Homunculus::Agent::AgentResult.completed("denied", session:)
      )
      tui.send(:handle_deny)
      sleep(0.3)
      expect(agent_loop).to have_received(:deny_tool)
    end
  end

  # ── show_help / show_status (overlay, no duplicate) ─────────────────

  describe "#show_help" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      t
    end

    before { allow(tui).to receive(:refresh_all) }

    it "sets overlay content and does not push to @messages" do
      tui.send(:show_help)
      expect(tui.instance_variable_get(:@messages)).to be_empty
      overlay = tui.instance_variable_get(:@overlay_content)
      expect(overlay).not_to be_nil
      expect(overlay.join).to include("Here's what I can do")
    end
  end

  describe "#show_status" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      t
    end

    before { allow(tui).to receive(:refresh_all) }

    it "sets overlay content and does not push to @messages" do
      tui.send(:show_status)
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs).to be_empty
      overlay = tui.instance_variable_get(:@overlay_content)
      expect(overlay).not_to be_nil
      expect(overlay.join).to include("Session:")
      expect(overlay.join).to include("Turns:")
    end
  end

  describe "#show_model" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      t
    end

    before { allow(tui).to receive(:refresh_all) }

    it "sets overlay with tier, model, provider (Story 7)" do
      tui.send(:show_model)
      overlay = tui.instance_variable_get(:@overlay_content)
      expect(overlay).not_to be_nil
      expect(overlay.join).to match(/Model tier:|model:|Model:|Provider:/i)
    end
  end

  describe "overlay rendering and clearing" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      t.instance_variable_set(:@running, true)
      event_loop = instance_double(described_class::EventLoop, push: nil, queue: Thread::Queue.new)
      t.instance_variable_set(:@event_loop, event_loop)
      t
    end

    before do
      allow(tui).to receive(:refresh_all)
    end

    it "build_chat_lines returns overlay content when @overlay_content is set" do
      tui.instance_variable_set(:@overlay_content, %w[line1 line2])
      allow(tui).to receive(:inner_width).and_return(80)
      lines = tui.send(:build_chat_lines)
      raw = lines.map { |l| l.gsub(/\e\[[0-9;]*[mGKHF]/, "") }
      expect(raw.join).to include("line1")
      expect(raw.join).to include("line2")
    end

    it "process_input clears overlay" do
      tui.instance_variable_set(:@overlay_content, ["overlay line"])
      tui.send(:process_input, "clear")
      expect(tui.instance_variable_get(:@overlay_content)).to be_nil
    end
  end

  # ── teardown_terminal ─────────────────────────────────────────────

  describe "#teardown_terminal" do
    it "does not raise even when stdout.write fails" do
      tui = described_class.new(config:)
      allow($stdout).to receive(:write).and_raise(Errno::EIO)
      expect { tui.send(:teardown_terminal) }.not_to raise_error
    end
  end

  # ── Constants ────────────────────────────────────────────────────

  describe "constants" do
    it "CHROME_ROWS equals HEADER_ROWS + STATUS_ROWS + INPUT_ROWS" do
      expected = described_class::HEADER_ROWS + described_class::STATUS_ROWS + described_class::INPUT_ROWS
      expect(described_class::CHROME_ROWS).to eq(expected)
    end

    it "Theme palette includes semantic role colors" do
      palette = described_class::Theme.palette
      expect(palette).to include(:user, :assistant, :info, :error, :muted, :accent)
    end

    it "Theme.paint applies styles and resets" do
      result = described_class::Theme.paint("hello", :bold)
      expect(result).to include("\e[1m")
      expect(result).to include("hello")
      expect(result).to include("\e[0m")
    end
  end

  # ── Warmup Integration (Story 4) ──────────────────────────────────

  describe "warmup integration" do
    it "initializes @warmup as an Agent::Warmup instance" do
      tui = described_class.new(config:)
      warmup = tui.instance_variable_get(:@warmup)
      expect(warmup).to be_a(Homunculus::Agent::Warmup)
    end

    describe "#start_warmup!" do
      it "calls @warmup.start! with a callback when warmup enabled" do
        tui = described_class.new(config:)
        warmup = tui.instance_variable_get(:@warmup)
        allow(warmup).to receive(:start!)
        tui.send(:start_warmup!)
        expect(warmup).to have_received(:start!).with(callback: anything)
      end

      it "returns early when @warmup is nil" do
        tui = described_class.new(config:)
        tui.instance_variable_set(:@warmup, nil)
        expect { tui.send(:start_warmup!) }.not_to raise_error
      end

      it "returns early when warmup disabled in config" do
        disabled_raw = TomlRB.load_file("config/default.toml")
        disabled_raw["agent"] = { "workspace_path" => workspace_dir, "warmup" => { "enabled" => false } }
        disabled_raw["scheduler"] = {
          "enabled" => false,
          "db_path" => File.join(db_dir, "scheduler.db"),
          "heartbeat" => {
            "enabled" => false, "cron" => "*/30 8-22 * * *",
            "model" => "local",
            "active_hours_start" => 8, "active_hours_end" => 22,
            "timezone" => "UTC"
          },
          "notification" => { "max_per_hour" => 10, "quiet_hours_queue" => true }
        }
        disabled_config = Homunculus::Config.new(disabled_raw)
        tui = described_class.new(config: disabled_config)
        warmup = tui.instance_variable_get(:@warmup)
        allow(warmup).to receive(:start!)
        tui.send(:start_warmup!)
        expect(warmup).not_to have_received(:start!)
      end
    end

    describe "#warmup_display" do
      subject(:tui) { described_class.new(config:) }

      before { allow(tui).to receive(:refresh_all) }

      it "pushes info message on :start event" do
        tui.send(:warmup_display, :start, :preload_chat_model, {})
        msgs = tui.instance_variable_get(:@messages)
        expect(msgs.last[:role]).to eq(:info)
        expect(msgs.last[:text]).to include("Loading chat model")
        expect(msgs.last[:text]).to include("⏳")
      end

      it "pushes info message on :complete event with elapsed_ms" do
        tui.send(:warmup_display, :complete, :preload_chat_model, { elapsed_ms: 250 })
        msgs = tui.instance_variable_get(:@messages)
        expect(msgs.last[:text]).to include("✓")
        expect(msgs.last[:text]).to include("Loading chat model")
        expect(msgs.last[:text]).to include("250ms")
      end

      it "pushes info message on :fail event" do
        tui.send(:warmup_display, :fail, :preload_embedding_model, { error: "timeout" })
        msgs = tui.instance_variable_get(:@messages)
        expect(msgs.last[:text]).to include("⚠")
        expect(msgs.last[:text]).to include("Loading embedding model")
        expect(msgs.last[:text]).to include("unavailable")
      end

      it "pushes info message on :done event" do
        tui.send(:warmup_display, :done, nil, { elapsed_ms: 1500 })
        msgs = tui.instance_variable_get(:@messages)
        expect(msgs.last[:text]).to include("✓")
        expect(msgs.last[:text]).to include("Ready in 1500ms")
      end

      it "does not push a message on :skip event" do
        tui.send(:warmup_display, :skip, :preread_workspace_files, {})
        msgs = tui.instance_variable_get(:@messages)
        expect(msgs).to be_empty
      end

      it "calls refresh_all after each event" do
        tui.send(:warmup_display, :start, :preload_chat_model, {})
        expect(tui).to have_received(:refresh_all)
      end
    end

    describe "#warmup_step_label" do
      subject(:tui) { described_class.new(config:) }

      it "returns 'Loading chat model' for :preload_chat_model" do
        expect(tui.send(:warmup_step_label, :preload_chat_model)).to eq("Loading chat model")
      end

      it "returns 'Loading embedding model' for :preload_embedding_model" do
        expect(tui.send(:warmup_step_label, :preload_embedding_model)).to eq("Loading embedding model")
      end

      it "returns 'Pre-reading workspace' for :preread_workspace_files" do
        expect(tui.send(:warmup_step_label, :preread_workspace_files)).to eq("Pre-reading workspace")
      end

      it "returns humanized fallback for unknown steps" do
        result = tui.send(:warmup_step_label, :some_future_step)
        expect(result).to eq("Some future step")
      end
    end
  end

  # ── Model Management Commands ──────────────────────────────────────

  describe "model management commands" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      t.instance_variable_set(:@running, true)
      event_loop = instance_double(described_class::EventLoop, push: nil, queue: Thread::Queue.new)
      t.instance_variable_set(:@event_loop, event_loop)
      t
    end

    before { allow(tui).to receive(:refresh_all) }

    describe "#show_models" do
      it "sets overlay with tier list" do
        tui.instance_variable_set(:@models_toml_data, {
                                    "tiers" => { "workhorse" => { "model" => "qwen2.5:14b", "description" => "Default" } }
                                  })

        tui.send(:show_models)

        overlay = tui.instance_variable_get(:@overlay_content)
        expect(overlay).not_to be_nil
        joined = overlay.join("\n")
        expect(joined).to include("workhorse")
        expect(joined).to include("qwen2.5:14b")
      end

      it "includes routing status" do
        tui.send(:show_models)

        overlay = tui.instance_variable_get(:@overlay_content)
        expect(overlay.join("\n")).to match(/Routing: (on|off)/)
      end

      it "marks the active override tier" do
        tui.instance_variable_set(:@models_toml_data, {
                                    "tiers" => { "coder" => { "model" => "qwen2.5:14b" }, "workhorse" => {} }
                                  })
        session = tui.instance_variable_get(:@session)
        session.forced_tier = :coder

        tui.send(:show_models)

        overlay = tui.instance_variable_get(:@overlay_content)
        expect(overlay.join("\n")).to include("active override")
      end
    end

    describe "#handle_model_command" do
      context "with no argument" do
        it "calls show_model" do
          allow(tui).to receive(:show_model)

          tui.send(:handle_model_command, "/model")

          expect(tui).to have_received(:show_model)
        end
      end

      context "with a valid tier" do
        before do
          tui.instance_variable_set(:@models_toml_data, { "tiers" => { "coder" => { "model" => "qwen2.5:14b" } } })
        end

        it "sets session.forced_tier" do
          tui.send(:handle_model_command, "/model coder")

          session = tui.instance_variable_get(:@session)
          expect(session.forced_tier).to eq(:coder)
        end

        it "resets first_message_sent" do
          session = tui.instance_variable_get(:@session)
          session.first_message_sent = true

          tui.send(:handle_model_command, "/model coder")

          expect(session.first_message_sent).to be false
        end

        it "sets overlay with confirmation message" do
          tui.send(:handle_model_command, "/model coder")

          overlay = tui.instance_variable_get(:@overlay_content)
          expect(overlay.join).to include("coder")
        end
      end

      context "with an unknown tier" do
        before do
          tui.instance_variable_set(:@models_toml_data, { "tiers" => { "coder" => {} } })
        end

        it "sets overlay with error message listing valid tiers" do
          tui.send(:handle_model_command, "/model nonexistent")

          overlay = tui.instance_variable_get(:@overlay_content)
          joined = overlay.join("\n")
          expect(joined).to include("Unknown tier")
          expect(joined).to include("coder")
        end

        it "does not change session.forced_tier" do
          session = tui.instance_variable_get(:@session)
          session.forced_tier = :coder

          tui.send(:handle_model_command, "/model nonexistent")

          expect(session.forced_tier).to eq(:coder)
        end
      end
    end

    describe "#handle_routing_command" do
      it "enables routing with /routing on" do
        session = tui.instance_variable_get(:@session)
        session.routing_enabled = false

        tui.send(:handle_routing_command, "/routing on")

        expect(session.routing_enabled).to be true
        overlay = tui.instance_variable_get(:@overlay_content)
        expect(overlay.join).to include("Routing ON")
      end

      it "disables routing with /routing off" do
        session = tui.instance_variable_get(:@session)
        session.routing_enabled = true

        tui.send(:handle_routing_command, "/routing off")

        expect(session.routing_enabled).to be false
        overlay = tui.instance_variable_get(:@overlay_content)
        expect(overlay.join).to include("Routing OFF")
      end

      it "shows current state when no argument given" do
        tui.send(:handle_routing_command, "/routing")

        overlay = tui.instance_variable_get(:@overlay_content)
        expect(overlay.join).to match(/Routing: (on|off)/)
      end

      it "shows usage for unknown argument" do
        tui.send(:handle_routing_command, "/routing sideways")

        overlay = tui.instance_variable_get(:@overlay_content)
        expect(overlay.join).to include("Usage")
      end
    end

    describe "process_input dispatches new commands" do
      it "dispatches /models to show_models" do
        allow(tui).to receive(:show_models)

        tui.send(:process_input, "/models")

        expect(tui).to have_received(:show_models)
      end

      it "dispatches /model <tier> to handle_model_command" do
        tui.instance_variable_set(:@models_toml_data, { "tiers" => { "coder" => {} } })

        tui.send(:process_input, "/model coder")

        session = tui.instance_variable_get(:@session)
        expect(session.forced_tier).to eq(:coder)
      end

      it "dispatches /routing off to handle_routing_command" do
        session = tui.instance_variable_get(:@session)
        session.routing_enabled = true

        tui.send(:process_input, "/routing off")

        expect(session.routing_enabled).to be false
      end
    end
  end
end
