# frozen_string_literal: true

require "sequel"
require "fileutils"
require "io/console"

module Homunculus
  module Interfaces
    # Terminal User Interface — full-screen chat experience.
    #
    # Layout (top to bottom):
    #   ┌─────────────────────────────────────┐  ← header bar
    #   │                                     │
    #   │          chat history               │  ← scrollable chat panel
    #   │                                     │
    #   ├─────────────────────────────────────┤
    #   │  model: local | tokens: 0↓ 0↑ | ... │  ← status bar
    #   ├─────────────────────────────────────┤
    #   │  > _                                │  ← input line
    #   └─────────────────────────────────────┘
    #
    # Rendering strategy: redraw only the changed regions (chat tail, status,
    # input) rather than clearing the full screen on every keystroke.
    class TUI
      include SemanticLogger::Loggable

      HEADER_ROWS  = 3
      STATUS_ROWS  = 1
      INPUT_ROWS   = 2
      CHROME_ROWS  = HEADER_ROWS + STATUS_ROWS + INPUT_ROWS

      ROLE_COLORS = {
        user: :cyan,
        assistant: :green,
        system: :yellow,
        error: :red,
        info: :dim
      }.freeze

      AGENT_NAME = "Homunculus"

      ANSI_CODES = {
        reset: "\e[0m",
        bold: "\e[1m",
        dim: "\e[2m",
        italic: "\e[3m",
        underline: "\e[4m",
        reverse: "\e[7m",
        red: "\e[31m",
        green: "\e[32m",
        yellow: "\e[33m",
        blue: "\e[34m",
        magenta: "\e[35m",
        cyan: "\e[36m",
        white: "\e[37m",
        bright_blue: "\e[94m",
        bright_green: "\e[92m",
        bright_cyan: "\e[96m"
      }.freeze

      def initialize(config:, provider_name: nil, model_override: nil)
        @config         = config
        @provider_name  = provider_name || "local"
        @model_override = model_override
        @running        = false
        @session        = nil
        @agent_loop     = nil
        @messages       = []   # [{role:, text:, lines: []}]
        @scroll_offset  = 0    # lines scrolled from the bottom
        @streaming_buf  = nil  # active streaming message entry
        @agent_name     = AGENT_NAME
        @identity_line  = load_identity

        setup_components!
      end

      def start
        @running = true
        @session = Session.new

        setup_signal_handlers
        @scheduler_manager&.start

        with_raw_terminal do
          initial_render
          input_loop
        end
      ensure
        teardown_terminal
        shutdown
      end

      private

      # ── Bootstrap ──────────────────────────────────────────────────

      def setup_components!
        @audit        = Security::AuditLogger.new(@config.security.audit_log_path)
        @memory_store = build_memory_store
        @tool_registry = build_tool_registry
        @prompt_builder = Agent::PromptBuilder.new(
          workspace_path: @config.agent.workspace_path,
          tool_registry: @tool_registry,
          memory: @memory_store
        )

        if use_models_router?
          @agent_loop = build_loop_with_models_router
        else
          model_config = resolve_model_config
          @provider   = Agent::ModelProvider.new(model_config)
          @agent_loop = Agent::Loop.new(
            config: @config,
            provider: @provider,
            tools: @tool_registry,
            prompt_builder: @prompt_builder,
            audit: @audit
          )
        end

        setup_scheduler! if @config.scheduler.enabled
      end

      def use_models_router?
        File.file?(models_toml_path)
      end

      def models_toml_path
        @models_toml_path ||= File.expand_path("config/models.toml", Dir.pwd)
      end

      def build_loop_with_models_router
        models_toml   = TomlRB.load_file(models_toml_path)
        ollama_config = (models_toml.dig("providers", "ollama") || {}).dup
        ollama_config["base_url"] =
          @config.models[:local]&.base_url || ollama_config["base_url"] || "http://127.0.0.1:11434"
        ollama_config["timeout_seconds"] =
          @config.models[:local]&.timeout_seconds ||
          ollama_config["timeout_seconds"] ||
          models_toml.dig("defaults", "timeout_seconds") || 120

        ollama_provider = Agent::Models::OllamaProvider.new(config: ollama_config)
        default_model   = @config.models[:local]&.default_model || @config.models[:local]&.model

        if default_model
          models_toml["tiers"] ||= {}
          models_toml["tiers"]["workhorse"] ||= {}
          models_toml["tiers"]["workhorse"] =
            models_toml["tiers"]["workhorse"].merge("model" => default_model)
        end

        models_router = Agent::Models::Router.new(
          config: models_toml,
          providers: { ollama: ollama_provider }
        )

        stream_cb = build_stream_callback
        Agent::Loop.new(
          config: @config,
          models_router: models_router,
          stream_callback: stream_cb,
          tools: @tool_registry,
          prompt_builder: @prompt_builder,
          audit: @audit
        )
      end

      def build_stream_callback
        lambda do |chunk|
          if @streaming_buf.nil?
            @streaming_buf = { role: :assistant, text: +"", lines: [] }
            @messages << @streaming_buf
          end
          @streaming_buf[:text] << chunk
          refresh_chat_panel
          refresh_status_bar
        end
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

      def build_tool_registry
        registry = Tools::Registry.new
        registry.register(Tools::Echo.new)
        registry.register(Tools::DatetimeNow.new)
        registry.register(Tools::WorkspaceRead.new)
        registry.register(Tools::WorkspaceWrite.new)
        registry.register(Tools::WorkspaceList.new)
        registry.register(Tools::ShellExec.new(config: @config))
        registry.register(Tools::WebFetch.new(config: @config))
        registry.register(Tools::WebExtract.new(config: @config))
        registry.register(Tools::MQTTPublish.new(config: @config))
        registry.register(Tools::MQTTSubscribe.new(config: @config))

        if @memory_store
          registry.register(Tools::MemorySearch.new(memory_store: @memory_store))
          registry.register(Tools::MemorySave.new(memory_store: @memory_store))
          registry.register(Tools::MemoryDailyLog.new(memory_store: @memory_store))
        end
        registry
      end

      def build_memory_store
        db_path = @config.memory.db_path
        FileUtils.mkdir_p(File.dirname(db_path))
        db = Sequel.sqlite(db_path)
        local_model_config = @config.models[:local]
        embedder = nil
        if local_model_config&.base_url
          embedder = Memory::Embedder.new(
            base_url: local_model_config.base_url,
            model: @config.memory.embedding_model
          )
        end
        store = Memory::Store.new(config: @config, db:, embedder:)
        store.rebuild_index! if db[:memory_chunks].none?
        store
      rescue StandardError => e
        logger.warn("Memory store initialization failed", error: e.message)
        nil
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
        service.deliver_fn = lambda { |text, _priority|
          push_info_message("[Scheduler] #{text}")
          refresh_all
        }
        service
      end

      # ── Terminal Setup ─────────────────────────────────────────────

      def with_raw_terminal
        # Redirect $stderr at the OS level so warn(), gems, and C extensions that
        # write directly to fd 2 don't bleed into the TUI's positioned rendering.
        log_path = File.expand_path("data/tui.log", Dir.pwd)
        FileUtils.mkdir_p(File.dirname(log_path))
        saved_stderr = $stderr.dup
        $stderr.reopen(log_path, "a")

        $stdout.write("\e[?1049h") # enter alternate screen
        $stdout.write("\e[?25l")   # hide cursor
        $stdout.flush
        yield
      ensure
        $stdout.write("\e[?25h")   # show cursor
        $stdout.write("\e[?1049l") # exit alternate screen
        $stdout.flush
        if defined?(saved_stderr) && saved_stderr
          $stderr.reopen(saved_stderr)
          saved_stderr.close rescue nil # rubocop:disable Style/RescueModifier
        end
      end

      def teardown_terminal
        $stdout.write("\e[?25h")
        $stdout.write("\e[?1049l")
        $stdout.flush
      rescue StandardError
        nil
      end

      def setup_signal_handlers
        trap("INT") do
          push_info_message("Interrupted — shutting down...")
          @running = false
        end
        trap("WINCH") do
          @term_width  = nil
          @term_height = nil
          initial_render
        end
      end

      # ── Dimensions ─────────────────────────────────────────────────

      def term_width
        @term_width ||= detect_width
      end

      def term_height
        @term_height ||= detect_height
      end

      def detect_width
        $stdout.winsize[1]
      rescue StandardError
        80
      end

      def detect_height
        $stdout.winsize[0]
      rescue StandardError
        24
      end

      def chat_rows
        [term_height - CHROME_ROWS, 4].max
      end

      def inner_width
        [term_width - 2, 10].max
      end

      # ── Full Render ────────────────────────────────────────────────

      def initial_render
        clear_screen
        render_header
        render_chat_panel
        render_status_bar
        render_input_line
      end

      def refresh_all
        render_chat_panel
        render_status_bar
        render_input_line
      end

      def clear_screen
        $stdout.write("\e[2J\e[H")
        $stdout.flush
      end

      # ── Header ─────────────────────────────────────────────────────

      def render_header
        move_to(1, 1)
        $stdout.write(paint(horizontal_rule("═"), :bright_blue))
        move_to(1, 2)
        date_str   = Time.now.strftime("%Y-%m-%d")
        title      = " #{AGENT_NAME} — #{@identity_line}"
        right_info = "#{date_str} "
        gap        = [term_width - visible_len(title) - visible_len(right_info), 0].max
        $stdout.write(
          paint(title, :bold) +
          (" " * gap) +
          paint(right_info, :dim)
        )
        move_to(1, 3)
        $stdout.write(paint(horizontal_rule("─"), :dim))
        $stdout.flush
      end

      # ── Chat Panel ─────────────────────────────────────────────────

      def render_chat_panel
        lines = build_chat_lines
        total  = lines.length
        window = chat_rows
        start  = [total - window - @scroll_offset, 0].max
        slice  = lines[start, window] || []

        (0...window).each do |i|
          row = HEADER_ROWS + 1 + i
          move_to(1, row)
          clear_line
          $stdout.write(slice[i] || "")
        end
        $stdout.flush
      end

      def refresh_chat_panel
        render_chat_panel
      end

      def build_chat_lines
        w = inner_width
        all_lines = []
        @messages.each do |msg|
          all_lines.concat(render_message(msg, w))
          all_lines << ""
        end
        all_lines
      end

      def render_message(msg, width)
        role  = msg[:role]
        text  = msg[:text].to_s
        label = role_label(role)
        color = ROLE_COLORS.fetch(role, :white)
        prefix_plain = "#{label}: "
        indent       = " " * visible_len(prefix_plain)

        lines = []
        text.split("\n").each_with_index do |para, para_idx|
          words = para.split
          current_line = para_idx.zero? ? prefix_plain : indent
          words.each do |word|
            if visible_len(current_line) + visible_len(word) + 1 > width
              lines << paint_role_line(current_line, color, para_idx.zero? && lines.empty?)
              current_line = indent + word
            else
              current_line += (current_line == indent || current_line == prefix_plain ? "" : " ") + word
            end
          end
          lines << paint_role_line(current_line, color, para_idx.zero? && lines.empty?) unless current_line.strip.empty?
        end
        lines.empty? ? [paint_role_line(prefix_plain, color, true)] : lines
      end

      def paint_role_line(line, color, is_label_line)
        return line if line.strip.empty?

        if is_label_line
          label_end = line.index(": ")
          if label_end
            label_part = line[0..(label_end + 1)]
            rest_part  = line[(label_end + 2)..]
            paint(label_part, color, :bold) + paint(rest_part.to_s, :reset)
          else
            paint(line, color)
          end
        else
          paint(line, :reset)
        end
      end

      def role_label(role)
        case role
        when :user      then "You"
        when :assistant then AGENT_NAME
        when :system    then "System"
        when :error     then "Error"
        else                 role.to_s.capitalize
        end
      end

      # ── Status Bar ─────────────────────────────────────────────────

      def render_status_bar
        row = HEADER_ROWS + chat_rows + 1
        move_to(1, row)
        clear_line
        $stdout.write(status_bar_content)
        $stdout.flush
      end

      def refresh_status_bar
        render_status_bar
      end

      def status_bar_content
        parts = [
          model_tier_label,
          token_usage_label,
          turn_label,
          session_status_label
        ]
        bar = " #{parts.compact.join("  |  ")}"
        pad = [term_width - visible_len(bar), 0].max
        paint(bar + (" " * pad), :reverse)
      end

      def model_tier_label
        tier = if use_models_router?
                 "router"
               else
                 @provider_name
               end
        "model: #{tier}"
      end

      def token_usage_label
        return nil unless @session

        in_t  = @session.total_input_tokens
        out_t = @session.total_output_tokens
        "tokens: #{in_t}↓ #{out_t}↑"
      end

      def turn_label
        return nil unless @session

        "turns: #{@session.turn_count}/#{@config.agent.max_turns}"
      end

      def session_status_label
        return nil unless @session

        pending = @session.pending_tool_call
        pending ? "pending: #{pending.name}" : "ready"
      end

      # ── Input Line ─────────────────────────────────────────────────

      def render_input_line(input_text = "")
        status_row = HEADER_ROWS + chat_rows + 1
        move_to(1, status_row + 1)
        clear_line
        $stdout.write(paint(horizontal_rule("─"), :dim))
        move_to(1, status_row + 2)
        clear_line
        prompt = paint("> ", :cyan, :bold)
        $stdout.write(prompt + input_text)
        $stdout.flush
      end

      # ── Input Loop ─────────────────────────────────────────────────

      def input_loop
        push_info_message("Type 'help' for commands. Ctrl+C to exit.")
        refresh_all

        while @running
          render_input_line
          input = read_line
          break if input.nil?

          input = input.scrub.strip
          process_input(input)
        end
      end

      def read_line
        buf = +""
        while @running
          begin
            char = $stdin.read_nonblock(1)
          rescue IO::WaitReadable
            $stdin.wait_readable(0.05)
            retry
          rescue EOFError
            return nil
          end

          case char
          when "\r", "\n"
            return buf
          when "\x03" # Ctrl+C
            @running = false
            return nil
          when "\x7f", "\b" # backspace / delete
            buf = buf[0..-2] || ""
            render_input_line(buf)
          when "\x1b" # escape sequences (arrow keys etc.)
            consume_escape_sequence
          else
            buf << char if char.ord >= 32
            render_input_line(buf)
          end
        end
        nil
      end

      def consume_escape_sequence
        seq = $stdin.read_nonblock(8)
        handle_scroll_keys(seq)
      rescue IO::WaitReadable
        nil
      end

      def handle_scroll_keys(seq)
        chat_line_count = build_chat_lines.length
        max_scroll = [chat_line_count - chat_rows, 0].max

        case seq
        when "[A", "[1;2A" # Up / Shift+Up
          @scroll_offset = [@scroll_offset + 3, max_scroll].min
          refresh_chat_panel
        when "[B", "[1;2B" # Down / Shift+Down
          @scroll_offset = [@scroll_offset - 3, 0].max
          refresh_chat_panel
        when "[5~" # Page Up
          @scroll_offset = [@scroll_offset + chat_rows, max_scroll].min
          refresh_chat_panel
        when "[6~" # Page Down
          @scroll_offset = [@scroll_offset - chat_rows, 0].max
          refresh_chat_panel
        end
      end

      def process_input(input)
        case input.downcase
        when "", nil
          nil
        when "exit", "quit", ":q"
          @running = false
        when "help"
          show_help
        when "status"
          show_status
        when "confirm"
          handle_confirm
        when "deny"
          handle_deny
        when "clear"
          @messages.clear
          @scroll_offset = 0
          refresh_all
        else
          handle_message(input)
        end
      end

      # ── Message Handling ───────────────────────────────────────────

      def handle_message(message)
        if @session.pending_tool_call
          push_info_message("Pending tool call — type 'confirm' or 'deny' first.")
          refresh_all
          return
        end

        push_user_message(message)
        refresh_all

        @streaming_buf = nil
        logger.info("TUI input", length: message.length, session_id: @session.id)

        result = @agent_loop.run(message, @session)
        @streaming_buf = nil
        @scroll_offset = 0
        display_result(result)
      rescue StandardError => e
        logger.error("Error processing message", error: e.message)
        push_error_message("Error: #{e.message}")
        refresh_all
      end

      def handle_confirm
        unless @session.pending_tool_call
          push_info_message("No pending action to confirm.")
          refresh_all
          return
        end
        push_info_message("Confirmed.")
        result = @agent_loop.confirm_tool(@session)
        @streaming_buf = nil
        @scroll_offset = 0
        display_result(result)
      rescue StandardError => e
        push_error_message("Error: #{e.message}")
        refresh_all
      end

      def handle_deny
        unless @session.pending_tool_call
          push_info_message("No pending action to deny.")
          refresh_all
          return
        end
        push_info_message("Denied.")
        result = @agent_loop.deny_tool(@session)
        @streaming_buf = nil
        @scroll_offset = 0
        display_result(result)
      rescue StandardError => e
        push_error_message("Error: #{e.message}")
        refresh_all
      end

      def display_result(result)
        case result.status
        when :completed
          # Non-streaming mode: push assistant message
          push_assistant_message(result.response) unless use_models_router?
        when :pending_confirmation
          tc = result.pending_tool_call
          push_info_message(
            "Tool call requires confirmation: #{tc.name} — args: #{tc.arguments.inspect}\n" \
            "Type 'confirm' to proceed or 'deny' to cancel."
          )
        when :error
          push_error_message(result.error.to_s)
        end
        refresh_all
      end

      # ── Message Queue ──────────────────────────────────────────────

      def push_user_message(text)
        @messages << { role: :user, text: text.to_s }
      end

      def push_assistant_message(text)
        @messages << { role: :assistant, text: text.to_s }
      end

      def push_info_message(text)
        @messages << { role: :info, text: text.to_s }
      end

      def push_error_message(text)
        @messages << { role: :error, text: text.to_s }
      end

      # ── Help & Status Overlays ─────────────────────────────────────

      def show_help
        help_text = <<~HELP.strip
          TUI Commands:
            help       — This message
            status     — Session and config details
            confirm    — Approve a pending tool call
            deny       — Reject a pending tool call
            clear      — Clear the chat history display
            quit / :q  — Exit
          Scroll:
            Arrow Up/Down or Page Up/Down to scroll history
        HELP
        push_info_message(help_text)
        refresh_all
      end

      def show_status
        pending = @session.pending_tool_call&.name || "none"
        mc      = use_models_router? ? nil : resolve_model_config
        model   = mc ? (mc.default_model || mc.model) : "router"
        status_text = <<~STATUS.strip
          Session:  #{@session.id}
          Turns:    #{@session.turn_count} / #{@config.agent.max_turns}
          Tokens:   #{@session.total_input_tokens}↓  #{@session.total_output_tokens}↑
          Duration: #{@session.duration.round(1)}s
          Pending:  #{pending}
          Model:    #{model}
          Provider: #{@provider_name}
          Workspace:#{@config.agent.workspace_path}
        STATUS
        push_info_message(status_text)
        refresh_all
      end

      # ── Shutdown ───────────────────────────────────────────────────

      def shutdown
        @scheduler_manager&.stop

        return unless @session

        @audit.log(
          action: "session_end",
          session_id: @session.id,
          **@session.summary.except(:id)
        )

        return unless @memory_store && @session.turn_count.positive?

        @memory_store.save_transcript(@session)
      rescue StandardError => e
        logger.warn("Shutdown error", error: e.message)
      end

      # ── ANSI / Rendering Helpers ───────────────────────────────────

      def paint(text, *styles)
        codes = styles.filter_map { |s| ANSI_CODES[s] }.join
        "#{codes}#{text}#{ANSI_CODES[:reset]}"
      end

      def move_to(col, row)
        $stdout.write("\e[#{row};#{col}H")
      end

      def clear_line
        $stdout.write("\e[2K\e[1G")
      end

      def horizontal_rule(char = "─")
        char * term_width
      end

      # Compute visible length (strip ANSI escape sequences)
      def visible_len(str)
        str.gsub(/\e\[[0-9;]*[mGKHF]/, "").length
      end
    end
  end
end
