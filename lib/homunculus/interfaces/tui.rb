# frozen_string_literal: true

require "sequel"
require "fileutils"
require "io/console"
require_relative "tui/theme"
require_relative "tui/input_buffer"
require_relative "tui/activity_indicator"
require_relative "tui/command_registry"
require_relative "tui/message_renderer"
require_relative "tui/screen_buffer"
require_relative "tui/ansi_parser"
require_relative "tui/keyboard_reader"
require_relative "tui/layout"
require_relative "tui/event_loop"
require_relative "tui/render_helpers"
require_relative "tui/setup_helpers"
require_relative "tui/message_helpers"
require_relative "tui/model_management_helpers"
require_relative "../agent/warmup"
require_relative "../sag/llm_adapter"
require_relative "../sag/pipeline_factory"
require_relative "sag_reachability"
require_relative "familiars_setup"

module Homunculus
  module Interfaces
    # Terminal User Interface — full-screen chat experience.
    # New components: ScreenBuffer, EventLoop, KeyboardReader, Layout.
    class TUI
      include SemanticLogger::Loggable
      include TUI::Theme
      include SAGReachability
      include TUI::RenderHelpers
      include TUI::SetupHelpers
      include TUI::MessageHelpers
      include TUI::ModelManagementHelpers
      include FamiliarsSetup

      HEADER_ROWS = 3
      STATUS_ROWS = 1
      INPUT_ROWS  = 2
      CHROME_ROWS = HEADER_ROWS + STATUS_ROWS + INPUT_ROWS

      AGENT_NAME  = "Homunculus"
      SCROLL_SEQS = ["[A", "[1;2A", "[B", "[1;2B", "[5~", "[6~"].freeze

      def initialize(config:, provider_name: nil, model_override: nil)
        @config         = config
        @provider_name  = provider_name || "local"
        @model_override = model_override
        @running        = false
        @session        = nil
        @agent_loop     = nil
        @messages       = []
        @messages_mutex = Mutex.new
        # Kept for test-suite compatibility (render_mutex checked by specs).
        @render_mutex   = Mutex.new
        @overlay_content  = nil
        @suggestion_lines = nil
        @command_registry = TUI::CommandRegistry.new
        @scroll_offset  = 0
        @streaming_buf  = nil
        @streaming_output_tokens_estimate = nil
        @agent_name     = AGENT_NAME
        @identity_line  = load_identity
        @current_tier   = nil
        @current_model  = nil
        @current_escalated_from = nil
        @current_context_window = nil
        # Frame components created in initialize_frame_components!
        @layout          = nil
        @screen          = nil
        @event_loop      = nil
        @keyboard_reader = nil
        @input_buffer    = nil
        @clock_thread    = nil
        @chat_lines_cache = nil
        @chat_lines_cache_key = nil

        setup_components!
      end

      def start
        @running = true
        @session = Session.new
        @session_start_time = Time.now

        setup_signal_handlers
        @scheduler_manager&.start

        with_raw_terminal do
          initialize_frame_components!
          start_warmup!
          push_greeting_messages
          render_frame(force: true)
          @keyboard_reader.start
          @event_loop.run
        end
      ensure
        @clock_thread&.kill
        @keyboard_reader&.stop
        @event_loop&.stop
        teardown_terminal
        print_session_summary
        shutdown
      end

      private

      # ── Bootstrap ────────────────────────────────────────────────

      def setup_components!
        @audit        = Security::AuditLogger.new(@config.security.audit_log_path)
        @memory_store = build_memory_store
        # Placeholder — reinitialised with real event_queue in initialize_frame_components!
        @activity_indicator = ActivityIndicator.new

        if use_models_router?
          build_models_router_infrastructure!
        else
          @provider = Agent::ModelProvider.new(resolve_model_config)
        end

        # Familiars must be initialized before tool registry (send_notification needs the dispatcher)
        @familiars_dispatcher = build_familiars_dispatcher
        @tool_registry = build_tool_registry
        warn_sag_disabled unless @config.sag.enabled
        @prompt_builder = Agent::PromptBuilder.new(
          workspace_path: @config.agent.workspace_path,
          tool_registry: @tool_registry,
          memory: @memory_store
        )

        status_cb = build_status_callback
        @agent_loop = if @models_router
                        build_loop_with_models_router(status_callback: status_cb)
                      else
                        Agent::Loop.new(
                          config: @config, provider: @provider, tools: @tool_registry,
                          prompt_builder: @prompt_builder, audit: @audit, status_callback: status_cb
                        )
                      end

        setup_scheduler! if @config.scheduler.enabled

        @warmup = Agent::Warmup.new(
          ollama_provider: @ollama_provider,
          embedder: @memory_store.respond_to?(:embedder) ? @memory_store.embedder : nil,
          config: @config,
          workspace_path: @config.agent.workspace_path
        )
      end

      def initialize_frame_components!
        w = detect_width
        h = detect_height
        @layout          = TUI::Layout.new(term_width: w, term_height: h)
        @screen          = TUI::ScreenBuffer.new(h, w)
        @input_buffer    = TUI::InputBuffer.new
        @event_loop      = TUI::EventLoop.new(render_fn: method(:handle_events))
        @keyboard_reader = TUI::KeyboardReader.new($stdin, @event_loop.queue)
        @activity_indicator = ActivityIndicator.new(event_queue: @event_loop.queue)
        start_clock_thread!
      end

      def start_clock_thread!
        @clock_thread = Thread.new do
          while @running
            sleep(1.0)
            @event_loop&.push({ type: :tick }) if @running
          end
        end
        @clock_thread.abort_on_exception = false
      end

      def build_stream_callback
        lambda do |chunk|
          @event_loop&.push({ type: :stream_chunk, chunk: })
        end
      end

      def build_status_callback
        lambda do |event, name|
          case event
          when :tool_start
            @activity_indicator&.update(name == "web_research" ? "Searching the web..." : "Running #{name}...")
          when :tool_end
            @activity_indicator&.update("Processing results...")
          end
          @event_loop&.push({ type: :tick })
        end
      end

      # ── Terminal Setup ───────────────────────────────────────────

      def with_raw_terminal(&)
        log_path = File.expand_path("data/tui.log", Dir.pwd)
        FileUtils.mkdir_p(File.dirname(log_path))
        saved_stderr = $stderr.dup
        $stderr.reopen(log_path, "a")
        $stdout.write("\e[?1049h")
        $stdout.write("\e[?25l")
        $stdout.write("\e[?7l")
        $stdout.flush
        $stdin.respond_to?(:raw) ? $stdin.raw(&) : yield
      ensure
        $stdout.write("\e[?7h")
        $stdout.write("\e[?25h")
        $stdout.write("\e[?1049l")
        $stdout.flush
        if defined?(saved_stderr) && saved_stderr
          $stderr.reopen(saved_stderr)
          saved_stderr.close rescue nil # rubocop:disable Style/RescueModifier
        end
      end

      def teardown_terminal
        $stdout.write("\e[?7h")
        $stdout.write("\e[?25h")
        $stdout.write("\e[?1049l")
        $stdout.flush
      rescue StandardError
        nil
      end

      def setup_signal_handlers
        trap("INT") do
          push_info_message("Interrupted — shutting down...")
          @event_loop&.push({ type: :shutdown })
        end
        trap("WINCH") do
          @event_loop&.push({ type: :resize })
        end
      end

      # ── Dimensions ───────────────────────────────────────────────

      def detect_width  = $stdout.winsize[1] rescue 80  # rubocop:disable Style/RescueModifier
      def detect_height = $stdout.winsize[0] rescue 24  # rubocop:disable Style/RescueModifier

      # Delegating accessors — used by specs and legacy code.
      def term_width  = @layout ? @layout.term_width  : detect_width
      def term_height = @layout ? @layout.term_height : detect_height
      def chat_rows   = @layout ? @layout.chat_rows   : [term_height - CHROME_ROWS, 4].max

      def inner_width
        @layout ? @layout.chat_width : [detect_width - 2, 10].max
      end

      # ── Event Loop Rendering ─────────────────────────────────────

      def handle_events(events)
        needs_full   = false
        needs_input  = false
        needs_status = false

        events.each do |event|
          case event[:type]
          when :key
            scope = handle_key_event(event)
            case scope
            when :full  then needs_full  = true
            when :input then needs_input = true
            end
          when :char
            scope = handle_char_event(event)
            case scope
            when :full  then needs_full  = true
            when :input then needs_input = true
            end
          when :stream_chunk
            handle_stream_chunk_event(event)
            needs_full = true
          when :spinner_tick, :tick
            needs_status = true
          when :refresh
            needs_full = true
          when :agent_result
            handle_agent_result_event(event)
            needs_full = true
          when :resize
            handle_resize_event
            needs_full = true
          when :notification
            handle_notification_event(event)
            needs_full = true
          when :familiars_test_result
            push_info_message("Familiars test results:\n#{event[:result]}")
            needs_full = true
          end
        end

        if needs_full
          render_frame
        elsif needs_input
          render_input_line_frame
          @screen.flush($stdout)
        elsif needs_status
          render_status_bar_frame
          @screen.flush($stdout)
        end
      end

      def render_frame(force: false)
        render_header_frame
        render_chat_panel_frame
        render_status_bar_frame
        render_input_line_frame
        if force
          @screen.force_flush($stdout)
        else
          @screen.flush($stdout)
        end
      end

      def handle_key_event(event)
        key = event[:key]
        case key
        when :enter
          handle_enter_key
          :full
        when :backspace
          @input_buffer.backspace
          update_suggestion_lines(@input_buffer)
          suggestion_scope
        when :ctrl_c
          handle_ctrl_c_key
          :full
        when :ctrl_u
          @input_buffer.clear
          update_suggestion_lines(@input_buffer)
          :input
        when :ctrl_w
          @input_buffer.delete_word_backward
          update_suggestion_lines(@input_buffer)
          :input
        when :tab
          apply_tab_completion(@input_buffer)
          update_suggestion_lines(@input_buffer)
          suggestion_scope
        when :ctrl_a, :home
          @input_buffer.move_home
          :input
        when :ctrl_e, :end_key
          @input_buffer.move_end
          :input
        when :ctrl_left
          @input_buffer.move_word_left
          :input
        when :ctrl_right
          @input_buffer.move_word_right
          :input
        when :arrow_left
          @input_buffer.move_left
          :input
        when :arrow_right
          @input_buffer.move_right
          :input
        when :ctrl_l
          :full
        when :arrow_up, :shift_up, :page_up, :arrow_down, :shift_down, :page_down
          handle_scroll_key(key)
          :full
        else
          :input
        end
      end

      def handle_enter_key
        line = @input_buffer.to_s.scrub.strip
        @input_buffer.clear
        @suggestion_lines = nil
        @suggestion_prefix = nil
        had_overlay = @messages_mutex.synchronize do
          was = !@overlay_content.nil?
          @overlay_content = nil
          was
        end
        process_input(line) unless line.empty? && !had_overlay
      end

      def handle_ctrl_c_key
        push_info_message("Interrupted — shutting down...")
        @event_loop&.push({ type: :shutdown })
      end

      def handle_char_event(event)
        char = event[:char]
        return :input unless char && char.ord >= 32

        @input_buffer.insert(char)
        update_suggestion_lines(@input_buffer)
        suggestion_scope
      end

      def suggestion_scope
        @suggestion_lines&.any? ? :full : :input
      end

      def handle_stream_chunk_event(event)
        first_chunk = append_stream_chunk(event[:chunk])
        @activity_indicator.stop if first_chunk
      end

      def handle_agent_result_event(event)
        result = event[:result]
        @messages_mutex.synchronize do
          @streaming_buf = nil
          @streaming_output_tokens_estimate = nil
        end
        display_result(result)
      rescue StandardError => e
        logger.error("Error handling agent result", error: e.message)
        push_error_message("Error: #{e.message}")
      ensure
        @activity_indicator&.stop
        @messages_mutex.synchronize do
          @streaming_buf = nil
          @streaming_output_tokens_estimate = nil
        end
      end

      def handle_resize_event
        w = detect_width
        h = detect_height
        @layout.resize(term_width: w, term_height: h)
        @screen.resize(h, w)
        render_frame(force: true)
      end

      def handle_notification_event(event)
        push_info_message(event[:text].to_s)
      end

      def handle_scroll_key(key)
        chat_line_count = build_chat_lines.length
        window = @layout.chat_rows
        max_scroll = [chat_line_count - window, 0].max
        @messages_mutex.synchronize do
          case key
          when :arrow_up,   :shift_up   then @scroll_offset = [@scroll_offset + 3, max_scroll].min
          when :arrow_down, :shift_down then @scroll_offset = [@scroll_offset - 3, 0].max
          when :page_up                 then @scroll_offset = [@scroll_offset + window, max_scroll].min
          when :page_down               then @scroll_offset = [@scroll_offset - window, 0].max
          end
        end
      end

      def push_greeting_messages
        @messages_mutex.synchronize do
          @messages << { role: :assistant, text: warm_greeting_text, timestamp: Time.now }
          @messages << { role: :info, text: session_context_line, timestamp: Time.now }
        end
      end

      # Legacy no-ops retained for module compatibility (SetupHelpers notification callback)
      def refresh_all = @event_loop&.push({ type: :refresh })
      def refresh_chat_and_status = @event_loop&.push({ type: :refresh })
      def refresh_status_bar = @event_loop&.push({ type: :tick })

      # Legacy string-based scroll handler — kept for spec compatibility.
      # Maps old CSI sequence strings to new symbol-based handler.
      def handle_scroll_keys(seq)
        key = case seq
              when "[A", "[1;2A" then :arrow_up
              when "[B", "[1;2B" then :arrow_down
              when "[5~"         then :page_up
              when "[6~"         then :page_down
              else return
              end
        handle_scroll_key(key)
      end

      # ── Chat Content ─────────────────────────────────────────────

      def build_chat_lines = chat_panel_snapshot[:lines]

      def cached_chat_lines(w)
        last = @messages.last
        key = [@messages.length, last&.dig(:text)&.length, w]
        return @chat_lines_cache if @chat_lines_cache && @chat_lines_cache_key == key

        @chat_lines_cache_key = key
        @chat_lines_cache = rendered_message_lines(@messages.map(&:dup), w)
      end

      def chat_panel_snapshot
        w = inner_width
        @messages_mutex.synchronize do
          overlay = @overlay_content&.dup
          lines = if overlay
                    overlay.flat_map { |line| wrap_plain_line(line, w) }.map { |line| paint(line, :muted) }
                  else
                    cached_chat_lines(w)
                  end
          { lines:, scroll_offset: @scroll_offset }
        end
      end

      def rendered_message_lines(messages, width)
        renderer = TUI::MessageRenderer.new(width:, agent_name: @agent_name)
        all_lines = []
        prev_role = nil
        prev_date = nil
        messages.each do |msg|
          msg_date = msg[:timestamp]&.to_date
          if prev_date && msg_date && prev_date != msg_date
            all_lines << paint(date_separator_line(msg[:timestamp], width), :muted)
          end
          all_lines << paint(turn_separator_line(width), :muted) if prev_role && prev_role != msg[:role]
          all_lines.concat(renderer.render(msg))
          all_lines << ""
          prev_role = msg[:role]
          prev_date = msg_date
        end
        all_lines
      end

      def turn_separator_line(width)
        seg = "#{Theme.turn_separator} "
        (seg * ((width / seg.length) + 1))[0, width]
      end

      def date_separator_line(ts, width)
        str = "── #{ts.strftime("%B %d, %Y")} ──"
        pad = [width - visible_len(str), 0].max
        (" " * (pad / 2)) + str + (" " * (pad - (pad / 2)))
      end

      def wrap_plain_line(text, width)
        words = text.to_s.split
        lines = []
        current = +""
        words.each do |word|
          if visible_len(current) + visible_len(word) + 1 > width
            lines << current.strip.dup unless current.strip.empty?
            current = +""
          else
            current << " " unless current.empty?
          end
          current << word
        end
        lines << current.strip unless current.strip.empty?
        lines.empty? ? [""] : lines
      end

      # ── Status Bar Content ───────────────────────────────────────

      def status_bar_model_label
        base = if @current_tier && @current_model then @current_tier.to_s
               elsif use_models_router? then "router"
               else @provider_name.to_s
               end
        @current_escalated_from ? "#{base} ⚡ escalated from #{@current_escalated_from}" : base
      end

      def model_tier_label
        if @current_tier && @current_model
          label = "model: #{@current_tier} (#{@current_model})"
          label += " ⚡ escalated from #{@current_escalated_from}" if @current_escalated_from
          label
        elsif use_models_router? then "model: router"
        else
          "model: #{@provider_name}"
        end
      end

      def model_tier_style
        return nil unless @current_tier
        return :bg_red if @current_escalated_from
        return :yellow if cloud_tier?(@current_tier)

        :green
      end

      def cloud_tier?(tier_name) = tier_name.to_s.start_with?("cloud_")

      def token_usage_label
        return nil unless @session

        in_t     = @session.total_input_tokens
        out_t    = @session.total_output_tokens
        estimate = @messages_mutex.synchronize { @streaming_output_tokens_estimate }
        ctx_win  = resolved_context_window

        base = if estimate&.positive?
                 "tokens: #{in_t}↓ #{out_t + estimate}↑ (+#{estimate}⚡)"
               else
                 "tokens: #{in_t}↓ #{out_t}↑"
               end

        return base unless ctx_win&.positive?

        # Use last-turn input tokens for ctx% — cumulative input inflates the ratio
        # beyond 100% after a few turns and is misleading vs the per-call window.
        last_in = @session.last_input_tokens
        ctx_out = estimate&.positive? ? out_t + estimate : out_t
        used    = last_in + ctx_out
        pct     = (used * 100.0 / ctx_win).round
        "#{base} ctx: #{format_token_count(used)}/#{format_token_count(ctx_win)} (#{pct}%)"
      end

      def format_token_count(n)
        n = n.to_i
        if n >= 1000
          k = (n / 100.0).round / 10.0
          k == k.to_i ? "#{k.to_i}k" : "#{k}k"
        else
          n.to_s
        end
      end

      def turn_label = @session ? "turns: #{@session.turn_count}/#{@config.agent.max_turns}" : nil

      def session_status_label
        return nil unless @session

        pending = @session.pending_tool_call
        pending ? "pending: #{pending.name}" : "ready"
      end

      def elapsed_session_time
        return nil unless @session_start_time

        elapsed = (Time.now - @session_start_time).to_i
        if elapsed >= 3600
          "#{elapsed / 3600}h #{(elapsed % 3600) / 60}m"
        else
          "#{elapsed / 60}m #{elapsed % 60}s"
        end
      end

      def update_suggestion_lines(buf)
        str = buf.respond_to?(:to_s) ? buf.to_s : buf.to_str
        if str.start_with?("/")
          @suggestion_lines  = @command_registry.suggestions_with_descriptions(str)
          @suggestion_prefix = str
        else
          @suggestion_lines  = nil
          @suggestion_prefix = nil
        end
      end

      def apply_tab_completion(buf)
        str = buf.to_s
        return false unless str.start_with?("/") && @suggestion_lines&.any?

        top = @suggestion_lines.first
        top_cmd = top.is_a?(Hash) ? top[:command] : top
        return false unless top_cmd && (str == top_cmd || top_cmd.start_with?(str))

        buf.clear
        top_cmd.each_char { |c| buf.insert(c) }
        update_suggestion_lines(buf)
        true
      end

      # ── Input Processing ─────────────────────────────────────────

      def process_input(input)
        @messages_mutex.synchronize { @overlay_content = nil }
        stripped = input.to_s.strip

        if stripped.start_with?("/")
          cmd_key = @command_registry.match(stripped)
          if cmd_key
            dispatch_slash_command(cmd_key, stripped)
          else
            @messages_mutex.synchronize { @overlay_content = ["Unknown command. Type /help for available commands."] }
            refresh_all
          end
          return
        end

        case stripped.downcase
        when "", nil then nil
        when "exit", "quit", ":q" then push_info_message("Shutting down...")
                                       @event_loop&.push({ type: :shutdown })
        when "help"     then show_help
        when "status"   then show_status
        when "confirm"  then handle_confirm
        when "deny"     then handle_deny
        when "clear"
          @messages_mutex.synchronize do
            @messages.clear
            @scroll_offset = 0
          end
          refresh_all
        else handle_message(input)
        end
      end

      def dispatch_slash_command(cmd_key, full_input = cmd_key)
        handler = TUI::CommandRegistry::COMMANDS[cmd_key][:handler]
        case handler
        when :show_help then show_help
        when :show_status then show_status
        when :clear then @messages_mutex.synchronize do
          @messages.clear
          @scroll_offset = 0
        end
                         refresh_all
        when :confirm then handle_confirm
        when :deny    then handle_deny
        when :show_models then show_models
        when :set_model   then handle_model_command(full_input)
        when :set_routing then handle_routing_command(full_input)
        when :handle_familiars_command then handle_familiars_command(full_input)
        when :quit then push_info_message("Shutting down...")
                        @event_loop&.push({ type: :shutdown })
        end
      end

      def handle_familiars_command(full_input)
        parts = full_input.strip.split(/\s+/, 2)
        subcommand = parts[1]&.strip&.downcase

        case subcommand
        when "status"
          show_familiars_status
        when "test"
          run_familiars_test
        else
          push_info_message("Usage: /familiars status | /familiars test")
        end
        refresh_all
      end

      def show_familiars_status
        unless @config.familiars.enabled
          push_info_message("Familiars: disabled (set FAMILIARS_ENABLED=true to enable)")
          return
        end
        unless @familiars_dispatcher
          push_info_message("Familiars: enabled in config but dispatcher not initialized")
          return
        end

        lines = ["Familiars Status:"]
        @familiars_dispatcher.status.each do |name, info|
          health = info[:healthy] ? "healthy" : "unreachable"
          enabled = info[:enabled] ? "enabled" : "disabled"
          lines << "  #{name}: #{enabled}, #{health}, #{info[:deliveries]} delivered, #{info[:failures]} failed"
        end
        push_info_message(lines.join("\n"))
      end

      def run_familiars_test
        unless @config.familiars.enabled && @familiars_dispatcher
          push_info_message("Familiars is disabled.")
          return
        end

        push_info_message("Sending Familiars test notification...")
        Thread.new do
          results = @familiars_dispatcher.notify(
            title: "Homunculus Test",
            message: "Familiars test from TUI. If you see this, notifications are working!",
            priority: :normal
          )
          result_lines = results.map { |ch, r| "  #{ch}: #{r}" }.join("\n")
          @event_loop&.push({ type: :familiars_test_result, result: result_lines })
        rescue StandardError => e
          logger.error("Familiars test error", error: e.message)
        end
      end

      # ── Message Handling ─────────────────────────────────────────

      def handle_message(message)
        if @session.pending_tool_call
          push_info_message("Pending tool call — type 'confirm' or 'deny' first.")
          return
        end
        push_user_message(message)
        @messages_mutex.synchronize do
          @streaming_buf = nil
          @streaming_output_tokens_estimate = nil
        end
        logger.info("TUI input", length: message.length, session_id: @session.id)
        @activity_indicator.start("Thinking...")
        Thread.new do
          result = @agent_loop.run(message, @session)
          @event_loop&.push({ type: :agent_result, result: })
        rescue StandardError => e
          logger.error("Agent thread error", error: e.message)
          @event_loop&.push({ type: :agent_result, result: build_error_result(e) })
        end
      end

      def update_context_window_from_result(result)
        return unless result.respond_to?(:context_window) && result.context_window&.positive?

        @current_context_window = result.context_window
      end

      def resolved_context_window
        @current_context_window || @config.models[:local]&.context_window
      end

      def build_error_result(error)
        Struct.new(:status, :error, :response, :tier, :model, :escalated_from,
                   :pending_tool_call, :context_window).new(:error, error.message, nil, nil, nil, nil, nil, nil)
      end

      def handle_confirm
        unless @session.pending_tool_call
          push_info_message("No pending action to confirm.")
          return
        end
        tool_name = @session.pending_tool_call.name
        @activity_indicator.start("Running #{tool_name}...")
        Thread.new do
          result = @agent_loop.confirm_tool(@session)
          push_info_message("#{Theme.utf8_capable? ? "✓" : "OK"} #{tool_name} completed")
          @messages_mutex.synchronize do
            @streaming_buf = nil
            @streaming_output_tokens_estimate = nil
          end
          @event_loop&.push({ type: :agent_result, result: })
        rescue StandardError => e
          logger.error("Confirm thread error", error: e.message)
          @event_loop&.push({ type: :agent_result, result: build_error_result(e) })
        end
      end

      def handle_deny
        unless @session.pending_tool_call
          push_info_message("No pending action to deny.")
          return
        end
        @activity_indicator.start("Denying...")
        Thread.new do
          result = @agent_loop.deny_tool(@session)
          push_info_message("Denied.")
          @messages_mutex.synchronize do
            @streaming_buf = nil
            @streaming_output_tokens_estimate = nil
          end
          @event_loop&.push({ type: :agent_result, result: })
        rescue StandardError => e
          logger.error("Deny thread error", error: e.message)
          @event_loop&.push({ type: :agent_result, result: build_error_result(e) })
        end
      end

      def display_result(result)
        case result.status
        when :completed
          if result.respond_to?(:tier) && result.tier
            @current_tier = result.tier
            @current_model = result.model
            @current_escalated_from = result.escalated_from
          end
          update_context_window_from_result(result)
          push_assistant_message(result.response) unless use_models_router?
        when :pending_confirmation
          tc = result.pending_tool_call
          @input_buffer&.clear
          @suggestion_lines = nil
          @suggestion_prefix = nil
          append_chat_message(role: :tool_request, tool_name: tc.name,
                              arguments: tc.arguments, timestamp: Time.now)
        when :error
          push_error_message(result.error.to_s)
        end
        refresh_all
      end

      # ── Message Queue ────────────────────────────────────────────

      def append_stream_chunk(chunk)
        first_chunk = false
        @messages_mutex.synchronize do
          preserve_scroll_position do
            if @streaming_buf.nil?
              @streaming_buf = { role: :assistant, text: +"", lines: [], timestamp: Time.now }
              @messages << @streaming_buf
              first_chunk = true
            end
            @streaming_buf[:text] << chunk
            @streaming_output_tokens_estimate = estimate_output_tokens(@streaming_buf[:text])
          end
        end
        first_chunk
      end

      def append_chat_message(message)
        @messages_mutex.synchronize { preserve_scroll_position { @messages << message } }
      end

      def preserve_scroll_position
        previous_count = rendered_message_lines(@messages, inner_width).length
        follow = @scroll_offset.zero?
        yield
        return if follow

        delta = rendered_message_lines(@messages, inner_width).length - previous_count
        @scroll_offset += delta if delta.positive?
      end

      def push_user_message(text)      = append_chat_message(role: :user, text: text.to_s, timestamp: Time.now)
      def push_assistant_message(text) = append_chat_message(role: :assistant, text: text.to_s, timestamp: Time.now)
      def push_info_message(text)      = append_chat_message(role: :info, text: text.to_s, timestamp: Time.now)

      def push_error_message(text)
        friendly = if text.to_s.start_with?("Error:")
                     "Hmm, something went wrong: #{text.to_s.sub(/\AError:\s*/, "")}"
                   else
                     text.to_s
                   end
        append_chat_message(role: :error, text: friendly, timestamp: Time.now)
      end

      def estimate_output_tokens(text)
        return 0 if text.nil? || text.empty?

        [(text.split(/\s+/).size * 1.3).round, (text.length / 4).round].max
      end

      # ── ANSI / Rendering Helpers ─────────────────────────────────

      # Kept for test-suite compatibility — render_mutex is checked by specs.
      def with_render_lock(&) = @render_mutex.synchronize(&)

      def normalize_terminal_text(text)
        value = text.to_s.dup
        return value if value.encoding == Encoding::UTF_8 && value.valid_encoding?

        value.force_encoding(Encoding::UTF_8).scrub
      end
    end
  end
end
