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

    it "starts with scroll offset 0" do
      tui = described_class.new(config:)
      expect(tui.instance_variable_get(:@scroll_offset)).to eq(0)
    end

    it "does not initialize scheduler when disabled" do
      tui = described_class.new(config:)
      expect(tui.instance_variable_get(:@scheduler_manager)).to be_nil
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

    it "push_user_message adds a user message" do
      tui.send(:push_user_message, "Hello!")
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.last).to include(role: :user, text: "Hello!")
    end

    it "push_assistant_message adds an assistant message" do
      tui.send(:push_assistant_message, "Hi there")
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.last).to include(role: :assistant, text: "Hi there")
    end

    it "push_info_message adds an info message" do
      tui.send(:push_info_message, "Info text")
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.last).to include(role: :info, text: "Info text")
    end

    it "push_error_message adds an error message" do
      tui.send(:push_error_message, "Something broke")
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.last).to include(role: :error, text: "Something broke")
    end
  end

  # ── Render Helpers ────────────────────────────────────────────────

  describe "#render_message" do
    subject(:tui) { described_class.new(config:) }

    it "renders a user message with the 'You' prefix" do
      msg   = { role: :user, text: "Hello world" }
      lines = tui.send(:render_message, msg, 80)
      joined = lines.join
      expect(joined).to include("You")
      expect(joined).to include("Hello world")
    end

    it "renders an assistant message with the agent name prefix" do
      msg   = { role: :assistant, text: "I can help" }
      lines = tui.send(:render_message, msg, 80)
      joined = lines.join
      expect(joined).to include(described_class::AGENT_NAME)
      expect(joined).to include("I can help")
    end

    it "wraps long lines at the specified width" do
      long_text = "word " * 30
      msg       = { role: :user, text: long_text.strip }
      lines     = tui.send(:render_message, msg, 40)
      raw_lines = lines.map { |l| tui.send(:visible_len, l) }
      expect(raw_lines.all? { |len| len <= 41 }).to be true
    end
  end

  # ── Role Labels ───────────────────────────────────────────────────

  describe "#role_label" do
    subject(:tui) { described_class.new(config:) }

    it "returns 'You' for :user" do
      expect(tui.send(:role_label, :user)).to eq("You")
    end

    it "returns agent name for :assistant" do
      expect(tui.send(:role_label, :assistant)).to eq(described_class::AGENT_NAME)
    end

    it "returns 'System' for :system" do
      expect(tui.send(:role_label, :system)).to eq("System")
    end

    it "returns 'Error' for :error" do
      expect(tui.send(:role_label, :error)).to eq("Error")
    end

    it "capitalizes unknown roles" do
      expect(tui.send(:role_label, :info)).to eq("Info")
    end
  end

  # ── Status Bar ────────────────────────────────────────────────────

  describe "#status_bar_content" do
    it "includes model tier" do
      tui = described_class.new(config:)
      tui.instance_variable_set(:@session, Homunculus::Session.new)
      content = tui.send(:status_bar_content)
      expect(tui.send(:visible_len, content)).to be > 0
      expect(content).to include("model:")
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
      expect(content).to include("turns:")
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

    it "pushes help info on 'help'" do
      allow(tui).to receive(:handle_message)
      tui.send(:process_input, "help")
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.any? { |m| m[:role] == :info && m[:text].include?("TUI Commands") }).to be true
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

    it "pushes info message on :pending_confirmation status" do
      tool_call = Homunculus::Agent::ModelProvider::ToolCall.new(
        id: "tc-1", name: "shell_exec", arguments: { command: "ls" }
      )
      result = Homunculus::Agent::AgentResult.pending_confirmation(
        tool_call,
        session: tui.instance_variable_get(:@session)
      )
      tui.send(:display_result, result)
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.any? { |m| m[:role] == :info && m[:text].include?("shell_exec") }).to be true
    end

    it "pushes error message on :error status" do
      result = Homunculus::Agent::AgentResult.error("Boom", session: tui.instance_variable_get(:@session))
      tui.send(:display_result, result)
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.any? { |m| m[:role] == :error && m[:text].include?("Boom") }).to be true
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
      expect(stdout_buf).to include(">")
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
      tui.send(:handle_message, "hello")
      msgs = tui.instance_variable_get(:@messages)
      expect(msgs.any? { |m| m[:role] == :error && m[:text].include?("network down") }).to be true
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

  # ── show_status ───────────────────────────────────────────────────

  describe "#show_status" do
    subject(:tui) do
      t = described_class.new(config:)
      t.instance_variable_set(:@session, Homunculus::Session.new)
      t
    end

    before { allow(tui).to receive(:refresh_all) }

    it "pushes a status info message" do
      tui.send(:show_status)
      msgs = tui.instance_variable_get(:@messages)
      info = msgs.find { |m| m[:role] == :info }
      expect(info).not_to be_nil
      expect(info[:text]).to include("Session:")
      expect(info[:text]).to include("Turns:")
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

    it "ROLE_COLORS includes all expected roles" do
      expect(described_class::ROLE_COLORS).to include(:user, :assistant, :system, :error, :info)
    end

    it "ANSI_CODES includes essential keys" do
      expect(described_class::ANSI_CODES).to include(:reset, :bold, :dim, :cyan, :green, :red, :reverse)
    end
  end
end
