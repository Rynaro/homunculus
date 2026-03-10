# frozen_string_literal: true

require "sequel"
require "fileutils"
require "io/console"
require_relative "tui/theme"
require_relative "tui/input_buffer"
require_relative "tui/activity_indicator"
require_relative "tui/command_registry"
require_relative "tui/message_renderer"
require_relative "../agent/warmup"
require_relative "../sag/llm_adapter"
require_relative "../sag/pipeline_factory"
require_relative "sag_reachability"

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
    # rubocop:disable Metrics/ClassLength
    class TUI
      include SemanticLogger::Loggable
      include TUI::Theme
      include SAGReachability

      HEADER_ROWS  = 3
      STATUS_ROWS  = 1
      INPUT_ROWS   = 2
      CHROME_ROWS  = HEADER_ROWS + STATUS_ROWS + INPUT_ROWS

      AGENT_NAME = "Homunculus"

      def initialize(config:, provider_name: nil, model_override: nil)
        @config         = config
        @provider_name  = provider_name || "local"
        @model_override = model_override
        @running        = false
        @session        = nil
        @agent_loop     = nil
        @messages       = []   # [{role:, text:, lines: []}]
        @messages_mutex = Mutex.new
        @render_mutex   = Mutex.new
        @overlay_content = nil # nil or array of lines (help/status overlay); cleared on next input
        @suggestion_lines = nil # nil or array of strings (slash command suggestions); transient, not in @messages
        @command_registry = TUI::CommandRegistry.new
        @scroll_offset  = 0    # lines scrolled from the bottom
        @streaming_buf  = nil  # active streaming message entry
        @streaming_output_tokens_estimate = nil # live estimate during stream (Integer or nil)
        @agent_name     = AGENT_NAME
        @identity_line  = load_identity
        @current_tier   = nil
        @current_model  = nil
        @current_escalated_from = nil

        setup_components!
      end

      def start
        @running = true
        @session = Session.new
        @session_start_time = Time.now

        setup_signal_handlers
        @scheduler_manager&.start

        with_raw_terminal do
          initial_render
          start_warmup!
          input_loop
        end
      ensure
        teardown_terminal
        print_session_summary
        shutdown
      end

      private

      # ── Bootstrap ──────────────────────────────────────────────────

      def setup_components!
        @audit        = Security::AuditLogger.new(@config.security.audit_log_path)
        @memory_store = build_memory_store
        @activity_indicator = ActivityIndicator.new(redraw: -> { refresh_status_bar })

        # Build provider infrastructure first — tool registry needs it for SAG wiring
        if use_models_router?
          build_models_router_infrastructure!
        else
          model_config = resolve_model_config
          @provider = Agent::ModelProvider.new(model_config)
        end

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
                          config: @config,
                          provider: @provider,
                          tools: @tool_registry,
                          prompt_builder: @prompt_builder,
                          audit: @audit,
                          status_callback: status_cb
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

      def use_models_router?
        File.file?(models_toml_path)
      end

      def models_toml_path
        @models_toml_path ||= File.expand_path("config/models.toml", Dir.pwd)
      end

      def build_models_router_infrastructure!
        models_toml   = TomlRB.load_file(models_toml_path)
        ollama_config = (models_toml.dig("providers", "ollama") || {}).dup
        ollama_config["base_url"] =
          @config.models[:local]&.base_url || ollama_config["base_url"] || "http://127.0.0.1:11434"
        ollama_config["timeout_seconds"] =
          @config.models[:local]&.timeout_seconds ||
          ollama_config["timeout_seconds"] ||
          models_toml.dig("defaults", "timeout_seconds") || 120

        @ollama_provider = Agent::Models::OllamaProvider.new(config: ollama_config)
        default_model    = @config.models[:local]&.default_model || @config.models[:local]&.model

        @models_toml_data = models_toml
        if default_model
          @models_toml_data["tiers"] ||= {}
          @models_toml_data["tiers"]["workhorse"] ||= {}
          @models_toml_data["tiers"]["workhorse"] =
            @models_toml_data["tiers"]["workhorse"].merge("model" => default_model)
        end

        @models_router = Agent::Models::Router.new(
          config: @models_toml_data,
          providers: { ollama: @ollama_provider }
        )
      end

      def build_loop_with_models_router(status_callback: nil)
        stream_cb = build_stream_callback
        Agent::Loop.new(
          config: @config,
          models_router: @models_router,
          stream_callback: stream_cb,
          tools: @tool_registry,
          prompt_builder: @prompt_builder,
          audit: @audit,
          status_callback: status_callback
        )
      end

      def build_stream_callback
        lambda do |chunk|
          first_chunk = append_stream_chunk(chunk)
          @activity_indicator.stop if first_chunk
          refresh_chat_and_status
        end
      end

      # Heuristic: word_count * 1.3 or char_count / 4 (whichever is larger).
      def estimate_output_tokens(text)
        return 0 if text.nil? || text.empty?

        words = text.split(/\s+/).size
        by_words = (words * 1.3).round
        by_chars = (text.length / 4).round
        [by_words, by_chars].max
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

        register_sag_tool(registry) if @config.sag.enabled
        registry
      end

      def register_sag_tool(registry)
        llm_adapter = build_sag_llm_adapter
        return unless llm_adapter
        return unless sag_backend_available?(logger, @config)

        embedder = @memory_store.respond_to?(:embedder) ? @memory_store.embedder : nil
        factory = SAG::PipelineFactory.new(
          config: @config.sag,
          llm_adapter: llm_adapter,
          embedder: embedder
        )
        registry.register(Tools::WebResearch.new(pipeline_factory: factory))
        logger.info("SAG web_research tool registered")
      rescue StandardError => e
        logger.warn("SAG tool registration failed — web_research unavailable", error: e.message)
      end

      def warn_sag_disabled
        logger.warn("SAG disabled in config — web_research unavailable until [sag].enabled is true and SearXNG is configured")
      end

      def build_sag_llm_adapter
        if @models_router
          SAG::LLMAdapter.new(router: @models_router)
        elsif @provider
          SAG::LLMAdapter.new(provider: @provider)
        end
      end

      def build_status_callback
        lambda do |event, name|
          case event
          when :tool_start
            label = name == "web_research" ? "Searching the web..." : "Running #{name}..."
            @activity_indicator&.update(label)
          when :tool_end
            @activity_indicator&.update("Processing results...")
          end
          refresh_status_bar
        end
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

      def with_raw_terminal(&)
        # Redirect $stderr at the OS level so warn(), gems, and C extensions that
        # write directly to fd 2 don't bleed into the TUI's positioned rendering.
        log_path = File.expand_path("data/tui.log", Dir.pwd)
        FileUtils.mkdir_p(File.dirname(log_path))
        saved_stderr = $stderr.dup
        $stderr.reopen(log_path, "a")

        $stdout.write("\e[?1049h") # enter alternate screen
        $stdout.write("\e[?25l")   # hide cursor
        $stdout.flush

        # Raw stdin: no echo, no line buffering — so arrow keys send escape sequences
        # that we can read and handle instead of being echoed as ^[[D etc.
        if $stdin.respond_to?(:raw)
          $stdin.raw(&)
        else
          yield
        end
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
        with_render_lock do
          clear_screen
          render_header_frame
          render_chat_panel_frame
          render_status_bar_frame
          render_input_line_frame
        end
      end

      def refresh_all
        with_render_lock do
          render_chat_panel_frame
          render_status_bar_frame
          render_input_line_frame
        end
      end

      def refresh_chat_and_status
        with_render_lock do
          render_chat_panel_frame
          render_status_bar_frame
        end
      end

      def clear_screen
        $stdout.write("\e[2J\e[H")
        $stdout.flush
      end

      # ── Header ─────────────────────────────────────────────────────

      def render_header
        with_render_lock { render_header_frame }
      end

      def render_header_frame
        move_to(1, 1)
        $stdout.write(paint(horizontal_rule(Theme::HEADER_TOP_CHAR), :accent))
        move_to(1, 2)
        date_str = Time.now.strftime("%A, %b %-d")
        title_centered = "#{Theme::HEADER_TITLE_FLANK} #{AGENT_NAME} #{Theme::HEADER_TITLE_FLANK}"
        title_len = visible_len(title_centered)
        date_len = visible_len(date_str)
        left_pad = [(term_width - title_len) / 2, 0].max
        right_pad = [term_width - left_pad - title_len - 1 - date_len, 0].max
        $stdout.write(
          "#{" " * left_pad}#{paint(title_centered, :bold)}#{" " * right_pad} #{paint(date_str, :muted)}"
        )
        move_to(1, 3)
        tagline = @identity_line.to_s.strip
        if tagline.empty?
          $stdout.write(paint(horizontal_rule(Theme::HEADER_BOTTOM_CHAR), :muted))
        else
          $stdout.write(paint(" #{tagline}", :muted))
        end
        $stdout.flush
      end

      # ── Chat Panel ─────────────────────────────────────────────────

      def render_chat_panel
        with_render_lock { render_chat_panel_frame }
      end

      def render_chat_panel_frame
        snapshot = chat_panel_snapshot
        lines = snapshot[:lines]
        total  = lines.length
        window = chat_rows
        max_scroll = [total - window, 0].max
        scroll_offset = [snapshot[:scroll_offset], max_scroll].min
        show_above = scroll_offset < max_scroll && max_scroll.positive?
        show_below = scroll_offset.positive?
        content_rows = window - (show_above ? 1 : 0) - (show_below ? 1 : 0)
        start = [total - content_rows - scroll_offset, 0].max
        slice = lines[start, content_rows] || []

        (0...window).each do |r|
          row = HEADER_ROWS + 1 + r
          move_to(1, row)
          clear_line
          line_str = if r.zero? && show_above
                       paint("▲ more above", :muted)
                     elsif r == window - 1 && show_below
                       paint("▼ more below", :muted)
                     else
                       idx = r - (show_above ? 1 : 0)
                       slice[idx] || ""
                     end
          $stdout.write(line_str)
        end
        $stdout.flush
      end

      def refresh_chat_panel
        with_render_lock { render_chat_panel_frame }
      end

      def build_chat_lines
        chat_panel_snapshot[:lines]
      end

      def chat_panel_snapshot
        w = inner_width
        @messages_mutex.synchronize do
          overlay = @overlay_content&.dup
          lines = if overlay
                    overlay.flat_map { |line| wrap_plain_line(line, w) }.map { |line| paint(line, :muted) }
                  else
                    rendered_message_lines(@messages.map(&:dup), w)
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
        seg = "#{Theme::TURN_SEPARATOR} "
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

      # ── Status Bar ─────────────────────────────────────────────────

      def render_status_bar
        with_render_lock { render_status_bar_frame }
      end

      def render_status_bar_frame
        row = HEADER_ROWS + chat_rows + 1
        move_to(1, row)
        # Overwrite in place (content is padded to term_width). Avoid clear_line to reduce blink.
        $stdout.write(status_bar_content)
        $stdout.flush
      end

      def refresh_status_bar
        with_render_lock { render_status_bar_frame }
      end

      def status_bar_content
        indicator = @activity_indicator&.snapshot
        scroll_offset = @messages_mutex.synchronize { @scroll_offset }
        sep = Theme::STATUS_SEP
        model_short = status_bar_model_label
        model_style = model_tier_style
        sections = [
          model_short ? "#{Theme::ROLE_ASSISTANT} #{model_short}" : nil,
          token_usage_label ? "#{token_usage_label} tokens" : nil,
          turn_label&.sub(/\Aturns: /, "turn "),
          elapsed_session_time,
          resolved_status_part(indicator:, scroll_offset:)
        ].compact
        raw = sections.join(sep)
        pad = [term_width - visible_len(" #{raw} "), 0].max
        out = " "
        sections.each_with_index do |s, i|
          out += paint(sep, :muted) if i.positive?
          out += if i.zero? && model_style
                   paint(s, model_style)
                 elsif i == sections.length - 1 && @session&.pending_tool_call
                   paint(s, :accent)
                 else
                   paint(s, :muted)
                 end
        end
        "#{out}#{" " * pad} "
      end

      def resolved_status_part(indicator:, scroll_offset:)
        return "#{indicator[:frame_char]} #{indicator[:message]}" if indicator&.fetch(:running, false)
        return "⚠ awaiting confirm" if @session&.pending_tool_call
        return "↕ scrolled" if scroll_offset.positive?

        session_status_label
      end

      def elapsed_session_time
        return nil unless @session_start_time

        elapsed = (Time.now - @session_start_time).to_i
        if elapsed >= 3600
          h = elapsed / 3600
          m = (elapsed % 3600) / 60
          "#{h}h #{m}m"
        else
          m = elapsed / 60
          s = elapsed % 60
          "#{m}m #{s}s"
        end
      end

      def status_bar_model_label
        base = if @current_tier && @current_model
                 @current_tier.to_s
               elsif use_models_router?
                 "router"
               else
                 @provider_name.to_s
               end
        @current_escalated_from ? "#{base} ⚡ escalated from #{@current_escalated_from}" : base
      end

      def model_tier_label
        if @current_tier && @current_model
          label = "model: #{@current_tier} (#{@current_model})"
          label += " ⚡ escalated from #{@current_escalated_from}" if @current_escalated_from
          label
        elsif use_models_router?
          "model: router"
        else
          "model: #{@provider_name}"
        end
      end

      # Style for the model segment: :green (local), :yellow (cloud), :bg_red (escalated).
      def model_tier_style
        return nil unless @current_tier

        return :bg_red if @current_escalated_from
        return :yellow if cloud_tier?(@current_tier)

        :green
      end

      def cloud_tier?(tier_name)
        tier_name.to_s.start_with?("cloud_")
      end

      def token_usage_label
        return nil unless @session

        in_t = @session.total_input_tokens
        out_t = @session.total_output_tokens
        estimate = @messages_mutex.synchronize { @streaming_output_tokens_estimate }
        if estimate&.positive?
          live_out = out_t + estimate
          "tokens: #{in_t}↓ #{live_out}↑ (+#{estimate}⚡)"
        else
          "tokens: #{in_t}↓ #{out_t}↑"
        end
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

      def update_suggestion_lines(input_buffer)
        buf_str = input_buffer.respond_to?(:to_s) ? input_buffer.to_s : input_buffer.to_str
        if buf_str.start_with?("/")
          @suggestion_lines = @command_registry.suggestions_with_descriptions(buf_str)
          @suggestion_prefix = buf_str
        else
          @suggestion_lines = nil
          @suggestion_prefix = nil
        end
      end

      # Completes input_buffer to the first suggestion when buffer starts with / and is a prefix. Returns true if completion was applied.
      def apply_tab_completion(input_buffer)
        buf_str = input_buffer.to_s
        return false unless buf_str.start_with?("/") && @suggestion_lines&.any?

        top = @suggestion_lines.first
        top_cmd = top.is_a?(Hash) ? top[:command] : top
        return false unless top_cmd && (buf_str == top_cmd || top_cmd.start_with?(buf_str))

        input_buffer.clear
        top_cmd.each_char { |c| input_buffer.insert(c) }
        update_suggestion_lines(input_buffer)
        true
      end

      # No args: empty line + hide cursor. With input_buffer: draw text + show cursor. Legacy: (text, cursor).
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def render_input_line(input_buffer_or_text = nil, cursor_pos = nil)
        with_render_lock { render_input_line_frame(input_buffer_or_text, cursor_pos) }
      end

      def render_input_line_frame(input_buffer_or_text = nil, cursor_pos = nil)
        status_row = HEADER_ROWS + chat_rows + 1
        input_row  = status_row + 2
        suggestion_entries = @suggestion_lines&.any? ? @suggestion_lines.first(5) : []

        # Only redraw separator line on full refresh (nil). During typing it never changes — avoids blink.
        if input_buffer_or_text.nil?
          move_to(1, status_row + 1)
          clear_line
          $stdout.write(paint(horizontal_rule(Theme::SEPARATOR_CHAR), :muted))
        end

        if suggestion_entries.any?
          prefix = @suggestion_prefix.to_s
          suggestion_entries.each_with_index do |entry, i|
            move_to(1, input_row - 1 - i)
            clear_line
            cmd = entry.is_a?(Hash) ? entry[:command] : entry
            desc = entry.is_a?(Hash) ? entry[:description] : nil
            line_str = desc ? "#{cmd} — #{desc}" : cmd.to_s
            if prefix.empty? || !cmd.to_s.start_with?(prefix)
              $stdout.write(paint(line_str, :muted))
            else
              $stdout.write(paint(cmd.to_s[0, prefix.length], :accent))
              $stdout.write(paint((cmd.to_s[prefix.length..] || "") + (desc ? " — #{desc}" : ""), :muted))
            end
          end
        else
          # Clear suggestion rows when not showing suggestions so stale "/confirm" etc. doesn't persist
          (0..4).each do |i|
            move_to(1, input_row - 1 - i)
            clear_line
          end
          # Restore the grey separator line above input (same row as first suggestion slot)
          move_to(1, status_row + 1)
          $stdout.write(paint(horizontal_rule(Theme::SEPARATOR_CHAR), :muted))
        end

        move_to(1, input_row)
        clear_line
        if input_buffer_or_text.nil?
          $stdout.write("\e[?25l")
          prompt = paint("#{Theme::PROMPT_CHAR} ", :user, :bold)
          $stdout.write(prompt)
          $stdout.write(paint("Type a message...", :muted))
        else
          text, cursor = if input_buffer_or_text.respond_to?(:cursor)
                           [input_buffer_or_text.to_s, input_buffer_or_text.cursor]
                         else
                           t = input_buffer_or_text.to_s
                           p = cursor_pos.nil? ? t.length : cursor_pos
                           [t, p.clamp(0, t.length)]
                         end
          text = normalize_terminal_text(text)
          $stdout.write("\e[?25h")
          prompt = paint("#{Theme::PROMPT_CHAR} ", :user, :bold)
          prompt_len = visible_len("#{Theme::PROMPT_CHAR} ")
          display_text = text
          display_text = nil if text.empty? # show placeholder below
          text_len = visible_len(display_text || "")
          char_count_str = (text.length > 100 ? " #{text.length} chars" : "")
          char_count_visible = char_count_str.length
          if display_text.nil?
            $stdout.write(prompt)
            $stdout.write(paint("Type a message...", :muted))
            col = 1 + prompt_len
          elsif char_count_visible.positive? && (prompt_len + text_len + char_count_visible <= term_width)
            $stdout.write(prompt + display_text)
            pad = term_width - prompt_len - text_len - char_count_visible
            $stdout.write(" " * pad) if pad.positive?
            $stdout.write(paint(char_count_str, :muted))
            col = 1 + prompt_len + (visible_len(text[0, cursor]) || 0)
          else
            $stdout.write(prompt + display_text)
            col = 1 + prompt_len + (visible_len(text[0, cursor]) || 0)
          end
          $stdout.write("\e[#{input_row};#{col}H")
        end
        $stdout.flush
      end

      # ── Input Loop ─────────────────────────────────────────────────

      def input_loop
        # Warm time-aware greeting as first assistant message; session context as info.
        @messages_mutex.synchronize do
          @messages << { role: :assistant, text: warm_greeting_text, timestamp: Time.now }
          @messages << { role: :info, text: session_context_line, timestamp: Time.now }
        end
        refresh_all

        while @running
          render_input_line
          input = read_line
          break if input.nil?

          input = input.scrub.strip
          had_overlay = @messages_mutex.synchronize do
            was_present = !@overlay_content.nil?
            @overlay_content = nil
            was_present
          end
          refresh_all if had_overlay
          process_input(input)
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

      # rubocop:disable Metrics/MethodLength
      def read_line
        input_buffer = TUI::InputBuffer.new
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
            return input_buffer.to_s
          when "\x03" # Ctrl+C
            @running = false
            return nil
          when "\t" # Tab — complete to top suggestion when buffer starts with /
            apply_tab_completion(input_buffer)
            render_input_line(input_buffer)
          when "\x01" # Ctrl+A — home
            input_buffer.move_home
            update_suggestion_lines(input_buffer)
            render_input_line(input_buffer)
          when "\x05" # Ctrl+E — end
            input_buffer.move_end
            render_input_line(input_buffer)
          when "\x15" # Ctrl+U — clear input line
            input_buffer.clear
            update_suggestion_lines(input_buffer)
            render_input_line(input_buffer)
          when "\x0C" # Ctrl+L — redraw screen
            refresh_all
            render_input_line(input_buffer)
          when "\x17" # Ctrl+W — delete word backward
            input_buffer.delete_word_backward
            update_suggestion_lines(input_buffer)
            render_input_line(input_buffer)
          when "\x7f", "\b" # backspace
            input_buffer.backspace
            update_suggestion_lines(input_buffer)
            render_input_line(input_buffer)
          when "\x1b" # escape sequences (arrow keys etc.)
            consume_escape_sequence(input_buffer)
            render_input_line(input_buffer)
          else
            input_buffer.insert(char) if char.ord >= 32
            update_suggestion_lines(input_buffer)
            render_input_line(input_buffer)
          end
        end
        nil
      end
      # rubocop:enable Metrics/MethodLength

      def consume_escape_sequence(input_buffer)
        @suggestion_lines = nil
        seq = read_escape_sequence
        case seq
        when "[D" then apply_cursor_action(input_buffer, :move_left)
        when "[C" then apply_cursor_action(input_buffer, :move_right)
        when "[H" then apply_cursor_action(input_buffer, :move_home)
        when "[F" then apply_cursor_action(input_buffer, :move_end)
        when "[1;5C" then apply_cursor_action(input_buffer, :move_word_right)
        when "[1;5D" then apply_cursor_action(input_buffer, :move_word_left)
        when "[A", "[1;2A", "[B", "[1;2B", "[5~", "[6~"
          handle_scroll_keys(seq)
        end
      end

      # Read the rest of an escape sequence after \e. Waits briefly so we don't leave bytes in the buffer.
      def read_escape_sequence
        $stdin.read_nonblock(8)
      rescue IO::WaitReadable
        $stdin.wait_readable(0.1)
        $stdin.read_nonblock(8)
      rescue EOFError
        ""
      end

      def apply_cursor_action(input_buffer, method_name)
        input_buffer.public_send(method_name)
        render_input_line(input_buffer)
      end

      def handle_scroll_keys(seq)
        chat_line_count = build_chat_lines.length
        max_scroll = [chat_line_count - chat_rows, 0].max

        @messages_mutex.synchronize do
          case seq
          when "[A", "[1;2A" # Up / Shift+Up
            @scroll_offset = [@scroll_offset + 3, max_scroll].min
          when "[B", "[1;2B" # Down / Shift+Down
            @scroll_offset = [@scroll_offset - 3, 0].max
          when "[5~" # Page Up
            @scroll_offset = [@scroll_offset + chat_rows, max_scroll].min
          when "[6~" # Page Down
            @scroll_offset = [@scroll_offset - chat_rows, 0].max
          end
        end
        refresh_chat_and_status
      end

      def process_input(input)
        @messages_mutex.synchronize { @overlay_content = nil }
        stripped = input.to_s.strip

        if stripped.start_with?("/")
          cmd_key = @command_registry.match(stripped)
          if cmd_key
            dispatch_slash_command(cmd_key)
          else
            @messages_mutex.synchronize do
              @overlay_content = ["Unknown command. Type /help for available commands."]
            end
            refresh_all
          end
          return
        end

        # Bare-word dispatch (backward compatibility)
        case stripped.downcase
        when "", nil
          nil
        when "exit", "quit", ":q"
          push_info_message("Shutting down...")
          refresh_all
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
          @messages_mutex.synchronize do
            @messages.clear
            @scroll_offset = 0
          end
          refresh_all
        else
          handle_message(input)
        end
      end

      def dispatch_slash_command(cmd_key)
        handler = TUI::CommandRegistry::COMMANDS[cmd_key][:handler]
        case handler
        when :show_help then show_help
        when :show_status then show_status
        when :clear
          @messages_mutex.synchronize do
            @messages.clear
            @scroll_offset = 0
          end
          refresh_all
        when :confirm then handle_confirm
        when :deny then handle_deny
        when :show_model then show_model
        when :quit
          push_info_message("Shutting down...")
          refresh_all
          @running = false
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

        @messages_mutex.synchronize do
          @streaming_buf = nil
          @streaming_output_tokens_estimate = nil
        end
        logger.info("TUI input", length: message.length, session_id: @session.id)

        @activity_indicator.start("Thinking...")
        agent_thread = Thread.new { @agent_loop.run(message, @session) }
        wait_for_agent_with_scroll(agent_thread)
        return unless @running

        agent_thread.join
        result = agent_thread.value
        @messages_mutex.synchronize do
          @streaming_buf = nil
          @streaming_output_tokens_estimate = nil
        end
        display_result(result)
      rescue StandardError => e
        logger.error("Error processing message", error: e.message)
        push_error_message("Error: #{e.message}")
        refresh_all
      ensure
        @activity_indicator&.stop
        @messages_mutex.synchronize do
          @streaming_buf = nil
          @streaming_output_tokens_estimate = nil
        end
      end

      # During agent execution: process only scroll keys and Ctrl+C; ignore other input.
      def wait_for_agent_with_scroll(agent_thread)
        while agent_thread.alive?
          break unless @running

          read_scroll_or_interrupt
        end
      end

      # Returns true if caller should stop waiting (e.g. Ctrl+C).
      def read_scroll_or_interrupt
        $stdin.wait_readable(0.05)
        char = $stdin.read_nonblock(1)
        case char
        when "\x03" # Ctrl+C
          @running = false
        when "\e"
          consume_escape_sequence_scroll_only
        end
        # Ignore other keys (no input_buffer in scroll-only mode)
      rescue IO::WaitReadable
        nil
      rescue EOFError
        @running = false
      end

      def consume_escape_sequence_scroll_only
        seq = read_escape_sequence
        case seq
        when "[A", "[1;2A", "[B", "[1;2B", "[5~", "[6~"
          handle_scroll_keys(seq)
        end
      end

      def handle_confirm
        unless @session.pending_tool_call
          push_info_message("No pending action to confirm.")
          refresh_all
          return
        end
        tool_name = @session.pending_tool_call.name
        result = @agent_loop.confirm_tool(@session)
        push_info_message("✓ #{tool_name} completed")
        @messages_mutex.synchronize do
          @streaming_buf = nil
          @streaming_output_tokens_estimate = nil
        end
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
        result = @agent_loop.deny_tool(@session)
        push_info_message("Denied.")
        @messages_mutex.synchronize do
          @streaming_buf = nil
          @streaming_output_tokens_estimate = nil
        end
        display_result(result)
      rescue StandardError => e
        push_error_message("Error: #{e.message}")
        refresh_all
      end

      def display_result(result)
        case result.status
        when :completed
          if result.respond_to?(:tier) && result.tier
            @current_tier = result.tier
            @current_model = result.model
            @current_escalated_from = result.escalated_from
          end
          # Non-streaming mode: push assistant message
          push_assistant_message(result.response) unless use_models_router?
        when :pending_confirmation
          tc = result.pending_tool_call
          append_chat_message(
            role: :tool_request,
            tool_name: tc.name,
            arguments: tc.arguments,
            timestamp: Time.now
          )
        when :error
          push_error_message(result.error.to_s)
        end
        refresh_all
      end

      # ── Message Queue ──────────────────────────────────────────────

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
        @messages_mutex.synchronize do
          preserve_scroll_position do
            @messages << message
          end
        end
      end

      def preserve_scroll_position
        previous_line_count = rendered_message_lines(@messages, inner_width).length
        follow_latest_output = @scroll_offset.zero?
        yield
        return if follow_latest_output

        current_line_count = rendered_message_lines(@messages, inner_width).length
        line_delta = current_line_count - previous_line_count
        @scroll_offset += line_delta if line_delta.positive?
      end

      def push_user_message(text)
        append_chat_message(role: :user, text: text.to_s, timestamp: Time.now)
      end

      def push_assistant_message(text)
        append_chat_message(role: :assistant, text: text.to_s, timestamp: Time.now)
      end

      def push_info_message(text)
        append_chat_message(role: :info, text: text.to_s, timestamp: Time.now)
      end

      def push_error_message(text)
        friendly = text.to_s.start_with?("Error:") ? "Hmm, something went wrong: #{text.to_s.sub(/\AError:\s*/, "")}" : text.to_s
        append_chat_message(role: :error, text: friendly, timestamp: Time.now)
      end

      # ── Warmup ─────────────────────────────────────────────────────

      def start_warmup!
        return if @warmup.nil? || !@config.agent.warmup.enabled

        @warmup.start!(callback: method(:warmup_display))
      end

      def warmup_display(event, step, detail)
        case event
        when :start
          push_info_message("⏳ #{warmup_step_label(step)}...")
        when :complete
          push_info_message("✓ #{warmup_step_label(step)} (#{detail[:elapsed_ms]}ms)")
        when :fail
          push_info_message("⚠ #{warmup_step_label(step)} unavailable")
        when :done
          push_info_message("✓ Ready in #{detail[:elapsed_ms]}ms")
        end
        refresh_all
      rescue StandardError => e
        logger.debug("Warmup display callback error", error: e.message)
      end

      def warmup_step_label(step)
        case step
        when :preload_chat_model then "Loading chat model"
        when :preload_embedding_model then "Loading embedding model"
        when :preread_workspace_files then "Pre-reading workspace"
        else step.to_s.tr("_", " ").capitalize
        end
      end

      def warm_greeting_text
        hour = Time.now.hour
        greeting = if hour >= 5 && hour < 12
                     "Good morning! Ready to help with whatever you need today."
                   elsif hour >= 12 && hour < 17
                     "Good afternoon! What are we working on?"
                   elsif hour >= 17 && hour < 22
                     "Good evening! How can I help?"
                   else
                     "Burning the midnight oil? I'm here when you need me."
                   end
        "#{greeting} Type /help for commands, or just start chatting."
      end

      def session_context_line
        tier = if @current_tier && @current_model
                 "#{@current_tier} (#{@current_model})"
               else
                 (use_models_router? ? "router" : @provider_name.to_s)
               end
        "Session started · model: #{tier} · /help for commands"
      end

      # ── Help & Status Overlays ─────────────────────────────────────

      def show_help
        help_text = <<~HELP.strip
          Here's what I can do:
            help       — This message
            status     — Session and config details
            confirm    — Approve a pending tool call
            deny       — Reject a pending tool call
            clear      — Clear the chat history display
            quit / :q  — Exit
          Scroll:
            Arrow Up/Down or Page Up/Down to scroll history
          Just type naturally — I understand plain language too.
        HELP
        @messages_mutex.synchronize { @overlay_content = help_text.split("\n") }
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
        @messages_mutex.synchronize { @overlay_content = status_text.split("\n") }
        refresh_all
      end

      def show_model
        tier_label = model_tier_label.sub(/\Amodel: /, "")
        mc = use_models_router? ? nil : resolve_model_config
        model_name = mc ? (mc.default_model || mc.model) : "router"
        provider   = @provider_name

        lines = [
          "Model tier: #{tier_label}",
          "Model:      #{model_name}",
          "Provider:   #{provider}"
        ]

        tier_descriptions = load_tier_descriptions_from_models_toml
        if tier_descriptions.any?
          lines << ""
          lines.concat(tier_descriptions)
        end

        @messages_mutex.synchronize { @overlay_content = lines }
        refresh_all
      end

      # Returns array of "  tier_name — description" lines from config/models.toml, or [].
      def load_tier_descriptions_from_models_toml
        return [] unless File.file?(models_toml_path)

        toml = TomlRB.load_file(models_toml_path)
        tiers = toml["tiers"] || {}
        tiers.map do |name, cfg|
          desc = cfg.is_a?(Hash) ? (cfg["description"] || "") : ""
          "  #{name} — #{desc}".strip
        end.reject { |line| line.end_with?(" — ") }
      end

      # ── Shutdown ───────────────────────────────────────────────────

      def format_int(n)
        n.to_s.gsub(/(\d)(?=(\d{3})+(?!\d))/, '\\1,')
      end

      def print_session_summary
        return unless @session && @session_start_time

        elapsed = (Time.now - @session_start_time).to_i
        duration_str = elapsed >= 3600 ? "#{elapsed / 3600}h #{(elapsed % 3600) / 60}m" : "#{elapsed / 60}m #{elapsed % 60}s"
        turns = "#{@session.turn_count}/#{@config.agent.max_turns}"
        in_t = @session.total_input_tokens
        out_t = @session.total_output_tokens
        token_str = "#{format_int(in_t)}↓ #{format_int(out_t)}↑"
        tool_count = @messages_mutex.synchronize { @messages.count { |m| m[:role] == :tool_request } }
        memory_line = @memory_store && @session.turn_count.positive? ? "Memory saved. " : ""
        lines = [
          "Session complete.",
          "Duration: #{duration_str} · Turns: #{turns} · Tokens: #{token_str}",
          (tool_count.positive? ? "Tools used: #{tool_count}. " : "") + "#{memory_line}See you next time!"
        ]
        $stdout.puts
        $stdout.puts(lines.join("\n"))
        $stdout.flush
      end

      def shutdown
        @activity_indicator&.stop
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

      def with_render_lock(&)
        @render_mutex.synchronize(&)
      end

      def normalize_terminal_text(text)
        value = text.to_s.dup
        return value if value.encoding == Encoding::UTF_8 && value.valid_encoding?

        value.force_encoding(Encoding::UTF_8)
        value.scrub
      end

      def move_to(col, row)
        $stdout.write("\e[#{row};#{col}H")
      end

      def clear_line
        $stdout.write("\e[2K\e[1G")
      end

      def horizontal_rule(char = Theme::SEPARATOR_CHAR)
        char * term_width
      end
      # rubocop:enable Metrics/ClassLength
    end
  end
end
