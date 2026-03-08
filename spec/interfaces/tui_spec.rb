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
      expect(tui.send(:term_width)).to be_positive
    end

    it "returns a positive term_height" do
      allow(tui).to receive(:detect_height).and_return(40)
      expect(tui.send(:term_height)).to be_positive
    end

    it "chat_rows is term_height minus chrome rows" do
      allow(tui).to receive_messages(detect_height: 30, detect_width: 80)
      expected = 30 - described_class::CHROME_ROWS
      expect(tui.send(:chat_rows)).to eq(expected)
    end

    it "inner_width is term_width minus 2" do
      allow(tui).to receive(:detect_width).and_return(80)
      expect(tui.send(:inner_width)).to eq(78)
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

    it "generates a horizontal rule at terminal width" do
      allow(tui).to receive(:detect_width).and_return(10)
      rule = tui.send(:horizontal_rule, "─")
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
      expect(content).to include("◆")
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

    it "applies red background to model segment when escalated (Story 8)" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@session, Homunculus::Session.new)
      tui.instance_variable_set(:@current_tier, "cloud_fast")
      tui.instance_variable_set(:@current_model, "claude-haiku")
      tui.instance_variable_set(:@current_escalated_from, "workhorse")
      allow(tui).to receive(:use_models_router?).and_return(true)
      content = tui.send(:status_bar_content)
      expect(content).to include("\e[41m") # bg_red
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
      t
    end

    before do
      allow(tui).to receive(:refresh_all)
      allow(tui).to receive(:render_input_line)
    end

    it "sets @running to false on 'quit'" do
      tui.send(:process_input, "quit")
      expect(tui.instance_variable_get(:@running)).to be false
    end

    it "sets @running to false on 'exit'" do
      tui.send(:process_input, "exit")
      expect(tui.instance_variable_get(:@running)).to be false
    end

    it "sets @running to false on ':q'" do
      tui.send(:process_input, ":q")
      expect(tui.instance_variable_get(:@running)).to be false
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

    it "/quit sets @running to false" do
      tui.send(:process_input, "/quit")
      expect(tui.instance_variable_get(:@running)).to be false
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
      t
    end

    before do
      allow(tui).to receive(:refresh_chat_panel)
      allow(tui).to receive_messages(detect_height: 30, detect_width: 80, build_chat_lines: ["line"] * 50)
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

  describe "rendering methods" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      t
    end

    let(:stdout_buf) { +"" }

    before do
      allow($stdout).to receive(:write) { |s| stdout_buf << s.to_s }
      allow($stdout).to receive(:flush)
      allow(tui).to receive_messages(detect_width: 80, detect_height: 24)
    end

    it "clear_screen writes ANSI clear escape" do
      tui.send(:clear_screen)
      expect(stdout_buf).to include("\e[2J")
    end

    it "move_to writes cursor positioning escape" do
      tui.send(:move_to, 1, 5)
      expect(stdout_buf).to include("\e[5;1H")
    end

    it "clear_line writes line-clear escape" do
      tui.send(:clear_line)
      expect(stdout_buf).to include("\e[2K")
    end

    it "render_header writes to stdout" do
      tui.send(:render_header)
      expect(stdout_buf).not_to be_empty
      expect(stdout_buf).to include(described_class::AGENT_NAME)
    end

    it "render_chat_panel writes to stdout" do
      tui.send(:push_user_message, "test message")
      tui.send(:render_chat_panel)
      expect(stdout_buf).not_to be_empty
    end

    it "render_status_bar writes to stdout" do
      tui.send(:render_status_bar)
      expect(stdout_buf).not_to be_empty
    end

    it "render_input_line writes prompt" do
      tui.send(:render_input_line, "test input")
      expect(stdout_buf).to include(described_class::Theme::PROMPT_CHAR)
    end

    it "initial_render calls all sub-renders" do
      expect(tui).to receive(:clear_screen)
      expect(tui).to receive(:render_header)
      expect(tui).to receive(:render_chat_panel)
      expect(tui).to receive(:render_status_bar)
      expect(tui).to receive(:render_input_line)
      tui.send(:initial_render)
    end

    it "refresh_all calls chat panel, status, and input renders" do
      expect(tui).to receive(:render_chat_panel)
      expect(tui).to receive(:render_status_bar)
      expect(tui).to receive(:render_input_line)
      tui.send(:refresh_all)
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

  describe "streaming callback" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      allow(t).to receive(:refresh_chat_panel)
      allow(t).to receive(:refresh_status_bar)
      t
    end

    it "build_stream_callback creates a callable" do
      cb = tui.send(:build_stream_callback)
      expect(cb).to respond_to(:call)
    end

    it "stream callback appends to streaming_buf" do
      cb = tui.send(:build_stream_callback)
      cb.call("hello ")
      cb.call("world")
      buf = tui.instance_variable_get(:@streaming_buf)
      expect(buf[:text]).to eq("hello world")
      expect(buf[:role]).to eq(:assistant)
    end

    it "stream callback adds the message to @messages on first chunk" do
      cb = tui.send(:build_stream_callback)
      msgs_before = tui.instance_variable_get(:@messages).length
      cb.call("first chunk")
      expect(tui.instance_variable_get(:@messages).length).to eq(msgs_before + 1)
    end

    it "stream callback does not add duplicate messages on subsequent chunks" do
      cb = tui.send(:build_stream_callback)
      cb.call("first")
      count_after_first = tui.instance_variable_get(:@messages).length
      cb.call("second")
      expect(tui.instance_variable_get(:@messages).length).to eq(count_after_first)
    end

    it "sets timestamp on streaming message when first chunk arrives" do
      cb = tui.send(:build_stream_callback)
      cb.call("first chunk")
      buf = tui.instance_variable_get(:@streaming_buf)
      expect(buf[:timestamp]).to be_a(Time)
    end

    it "stops activity indicator on first chunk (Story 3)" do
      indicator = tui.instance_variable_get(:@activity_indicator)
      allow(indicator).to receive(:stop).and_call_original
      cb = tui.send(:build_stream_callback)
      cb.call("first")
      expect(indicator).to have_received(:stop)
    end

    it "updates streaming_output_tokens_estimate as chunks arrive (Story 4)" do
      cb = tui.send(:build_stream_callback)
      cb.call("one")
      estimate1 = tui.instance_variable_get(:@streaming_output_tokens_estimate)
      expect(estimate1).to be_a(Integer)
      expect(estimate1).to be >= 1
      cb.call(" two three four five")
      estimate2 = tui.instance_variable_get(:@streaming_output_tokens_estimate)
      expect(estimate2).to be > estimate1
    end

    it "sets streaming_output_tokens_estimate from word and char heuristic" do
      cb = tui.send(:build_stream_callback)
      cb.call("hello world")
      estimate = tui.instance_variable_get(:@streaming_output_tokens_estimate)
      expect(estimate).to be_a(Integer)
      expect(estimate).to be >= 1
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
      expect(label).to eq("tokens: 100↓ 50↑")
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
      expect(label).to eq("tokens: 300↓ 120↑")
    end
  end

  # ── handle_message ────────────────────────────────────────────────

  describe "#handle_message" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      t.instance_variable_set(:@running, true)
      t
    end

    before do
      allow(tui).to receive(:refresh_all)
      allow(tui).to receive(:render_input_line)
      allow(tui).to receive(:display_result)
    end

    it "pushes a user message before calling agent loop" do
      agent_loop = tui.instance_variable_get(:@agent_loop)
      session    = tui.instance_variable_get(:@session)
      allow(agent_loop).to receive(:run).and_return(
        Homunculus::Agent::AgentResult.completed("ok", session:)
      )
      tui.send(:handle_message, "what time is it?")
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

    it "pushes an error message when the agent loop raises" do
      agent_loop = tui.instance_variable_get(:@agent_loop)
      allow(agent_loop).to receive(:run).and_raise(StandardError, "network down")
      indicator = tui.instance_variable_get(:@activity_indicator)
      allow(indicator).to receive(:start)
      allow(indicator).to receive(:stop)
      allow(Thread).to receive(:new) { |&block| block.call; double("thread", alive?: false, join: nil, value: nil) }
      tui.send(:handle_message, "hello")
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.any? { |m| m[:role] == :error && m[:text].include?("network down") }).to be true
    end

    it "runs agent in a background thread so main thread can process scroll (wait loop exits when thread finishes)" do
      agent_loop = tui.instance_variable_get(:@agent_loop)
      session = tui.instance_variable_get(:@session)
      result = Homunculus::Agent::AgentResult.completed("done", session:)
      allow(agent_loop).to receive(:run).and_return(result)
      indicator = tui.instance_variable_get(:@activity_indicator)
      allow(indicator).to receive(:start)
      allow(indicator).to receive(:stop)
      allow(Thread).to receive(:new) do |&block|
        r = block.call
        double("thread", alive?: false, join: nil, value: r)
      end
      tui.send(:handle_message, "ping")
      expect(tui).to have_received(:display_result).with(result)
    end

    it "starts activity indicator before agent and stops it in ensure (Story 3)" do
      agent_loop = tui.instance_variable_get(:@agent_loop)
      session = tui.instance_variable_get(:@session)
      allow(agent_loop).to receive(:run).and_return(
        Homunculus::Agent::AgentResult.completed("ok", session:)
      )
      indicator = tui.instance_variable_get(:@activity_indicator)
      allow(indicator).to receive(:start).and_call_original
      allow(indicator).to receive(:stop).and_call_original
      tui.send(:handle_message, "hello")
      expect(indicator).to have_received(:start).with("Thinking...")
      expect(indicator).to have_received(:stop)
    end

    it "clears streaming_output_tokens_estimate after agent completes (Story 4)" do
      agent_loop = tui.instance_variable_get(:@agent_loop)
      session = tui.instance_variable_get(:@session)
      allow(agent_loop).to receive(:run).and_return(
        Homunculus::Agent::AgentResult.completed("done", session:)
      )
      tui.instance_variable_set(:@streaming_output_tokens_estimate, 42)
      tui.send(:handle_message, "ping")
      expect(tui.instance_variable_get(:@streaming_output_tokens_estimate)).to be_nil
    end
  end

  # ── Story 2: Mutex and scroll during agent ─────────────────────────

  describe "message buffer mutex and scroll during streaming" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      allow(t).to receive_messages(detect_width: 80, detect_height: 24)
      t
    end

    it "allows concurrent stream callback and build_chat_lines without raising" do
      cb = tui.send(:build_stream_callback)
      reader = Thread.new do
        20.times { tui.send(:build_chat_lines) }
      end
      writer = Thread.new do
        20.times { |i| cb.call(" chunk #{i}") }
      end
      expect do
        reader.join(2)
        writer.join(2)
      end.not_to raise_error
    end

    it "handle_scroll_keys updates scroll_offset and can be called while messages exist (mutex-held reads)" do
      tui.send(:push_user_message, "one")
      tui.send(:push_assistant_message, "two")
      allow(tui).to receive(:refresh_chat_panel)
      tui.send(:handle_scroll_keys, "[5~")
      expect(tui.instance_variable_get(:@scroll_offset)).to be >= 0
    end
  end

  describe "scroll indicators in render_chat_panel" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      allow(t).to receive_messages(detect_width: 80, detect_height: 24, chat_rows: 6)
      t
    end

    let(:stdout_buf) { +"" }

    before do
      allow($stdout).to receive(:write) { |s| stdout_buf << s.to_s }
      allow($stdout).to receive(:flush)
    end

    it "shows ▲ more above when scrolled up and not at top" do
      5.times { |i| tui.send(:push_user_message, "msg #{i} " + ("x " * 20)) }
      # Many lines so max_scroll is large; scroll_offset 2 leaves content above
      tui.instance_variable_set(:@scroll_offset, 2)
      tui.send(:render_chat_panel)
      raw = stdout_buf.gsub(/\e\[[0-9;]*[mGKHF]/, "")
      expect(raw).to include("▲ more above")
    end

    it "shows ▼ more below when user has scrolled up (scroll_offset > 0)" do
      tui.send(:push_user_message, "line 1")
      long_content = "word " * 30
      tui.send(:push_assistant_message, "line 2 #{long_content}")
      tui.instance_variable_set(:@scroll_offset, 3)
      tui.send(:render_chat_panel)
      raw = stdout_buf.gsub(/\e\[[0-9;]*[mGKHF]/, "")
      expect(raw).to include("▼ more below")
    end
  end

  # ── handle_confirm / handle_deny ─────────────────────────────────

  describe "#handle_confirm and #handle_deny" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      t
    end

    before do
      allow(tui).to receive(:refresh_all)
      allow(tui).to receive(:display_result)
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
      t
    end

    before do
      allow(tui).to receive(:refresh_all)
      allow(tui).to receive(:render_input_line)
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
end
