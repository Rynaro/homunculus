# frozen_string_literal: true

module Homunculus
  module Interfaces
    class TUI
      # Rendering helpers that write exclusively to @screen (ScreenBuffer).
      # No $stdout.write, no move_to, no clear_line here.
      # All row positions come from @layout. Flushed once per frame by render_frame.
      module RenderHelpers # rubocop:disable Metrics/ModuleLength
        # ── Header ──────────────────────────────────────────────────

        def render_header_frame
          w = @layout.term_width
          @screen.write(1, 1, paint(horizontal_rule(Theme.header_top_char, w), :accent))
          render_header_title_row
          render_header_tagline_row
        end

        def render_header_title_row
          w        = @layout.term_width
          date_str = Time.now.strftime("%a %b %-d")
          logo     = Theme.utf8_capable? ? "⬡" : "*"
          left_str  = " #{logo} #{AGENT_NAME}"
          left_len  = visible_len(left_str)
          date_len  = visible_len(date_str)
          gap_len   = [w - left_len - date_len - 1, 0].max
          row_content = "#{paint(left_str, :bold, :accent)}#{" " * gap_len} #{paint(date_str, :muted)}"
          bg = Theme.ansi_for(:bg_header)
          @screen.write(1, 2, "#{bg}#{row_content}#{Theme::RESET}#{" " * [w - left_len - gap_len - date_len - 1, 0].max}")
        end

        def render_header_tagline_row
          w       = @layout.term_width
          tagline = @identity_line.to_s.strip
          bg      = Theme.ansi_for(:bg_header)
          content = if tagline.empty?
                      paint(horizontal_rule(Theme.header_bottom_char, w), :muted)
                    else
                      " #{paint(tagline, :muted)}"
                    end
          @screen.write(1, 3, "#{bg}#{content}#{Theme::RESET}")
        end

        # ── Chat Panel ──────────────────────────────────────────────

        def render_chat_panel_frame
          snapshot      = chat_panel_snapshot
          lines         = snapshot[:lines]
          total         = lines.length
          window        = @layout.chat_rows
          max_scroll    = [total - window, 0].max
          scroll_offset = [snapshot[:scroll_offset], max_scroll].min
          show_above    = scroll_offset < max_scroll && max_scroll.positive?
          show_below    = scroll_offset.positive?
          content_rows  = window - (show_above ? 1 : 0) - (show_below ? 1 : 0)
          start         = [total - content_rows - scroll_offset, 0].max
          slice         = lines[start, content_rows] || []

          @layout.chat_region.each_with_index do |row, r|
            @screen.clear_row(row)
            line_str = chat_line_content(r, window, show_above, show_below, slice)
            @screen.write(1, row, line_str) unless line_str.empty?
          end

          render_command_palette_overlay if @suggestion_lines&.any?
        end

        def chat_line_content(r, window, show_above, show_below, slice)
          if r.zero? && show_above
            paint("▲ more above", :muted)
          elsif r == window - 1 && show_below
            paint("▼ more below", :muted)
          else
            idx = r - (show_above ? 1 : 0)
            slice[idx] || ""
          end
        end

        # ── Status Bar ──────────────────────────────────────────────

        def render_status_bar_frame
          row = @layout.status_row
          @screen.clear_row(row)
          @screen.write(1, row, status_bar_content)
        end

        def status_bar_content
          indicator     = @activity_indicator&.snapshot
          scroll_offset = @messages_mutex.synchronize { @scroll_offset }
          sep           = Theme.status_sep
          sections      = build_status_sections(indicator, scroll_offset)
          raw           = sections.join(sep)
          w             = @layout ? @layout.term_width : term_width
          pad           = [w - visible_len(" #{raw} "), 0].max
          format_status_bar(sections, pad, sep)
        end

        def build_status_sections(indicator, scroll_offset)
          dot = status_bar_model_label ? "#{model_tier_dot} #{status_bar_model_label}" : nil
          [
            dot,
            token_usage_label ? "#{token_usage_label} tokens" : nil,
            turn_label&.sub(/\Aturns: /, "turn "),
            elapsed_session_time,
            resolved_status_part(indicator:, scroll_offset:)
          ].compact
        end

        def model_tier_dot
          tier = if @current_escalated_from
                   :escalated
                 elsif @current_tier && cloud_tier?(@current_tier)
                   :cloud
                 elsif @current_tier
                   :local
                 end
          Theme.model_dot(tier)
        end

        def format_status_bar(sections, pad, sep)
          bg  = Theme.ansi_for(:bg_status)
          out = "#{bg} "
          sections.each_with_index do |s, i|
            out += paint(sep, :muted) if i.positive?
            out += if i.zero?
                     s
                   elsif i == sections.length - 1 && @session&.pending_tool_call
                     paint(s, :accent)
                   else
                     paint(s, :muted)
                   end
          end
          "#{out}#{" " * pad} #{Theme::RESET}"
        end

        def resolved_status_part(indicator:, scroll_offset:)
          return "#{indicator[:frame_char]} #{indicator[:message]}" if indicator&.fetch(:running, false)
          return "⚠ awaiting confirm" if @session&.pending_tool_call
          return "↕ scrolled" if scroll_offset.positive?

          session_status_label
        end

        # ── Command Palette Overlay ──────────────────────────────────

        def render_command_palette_overlay
          entries = @suggestion_lines.first(8)
          return if entries.empty?

          w         = @layout.term_width
          palette_w = (w - 4).clamp(40, 74)
          inner_w   = palette_w - 2
          palette_h = entries.length + 2
          chat_end  = @layout.chat_end_row
          top_row   = [chat_end - palette_h + 1, @layout.chat_start_row].max
          left_col  = 2

          bg     = Theme.ansi_for(:bg_code)
          border = Theme.ansi_for(:accent)
          sep    = Theme.utf8_capable? ? "─" : "-"
          tl     = Theme.utf8_capable? ? "╭" : "+"
          tr     = Theme.utf8_capable? ? "╮" : "+"
          bl     = Theme.utf8_capable? ? "╰" : "+"
          br     = Theme.utf8_capable? ? "╯" : "+"
          vert   = Theme.utf8_capable? ? "│" : "|"

          render_palette_top_border(left_col, top_row, inner_w, tl, tr, sep, bg, border)
          render_palette_entries(entries, left_col, top_row, inner_w, vert, bg, border)
          render_palette_bottom_border(left_col, top_row, palette_h, inner_w, bl, br, sep, bg, border)
        end

        def render_palette_top_border(left_col, top_row, inner_w, tl, tr, sep, bg, border) # rubocop:disable Metrics/ParameterLists
          title      = " Commands "
          title_str  = paint(title, :bold)
          fill_len   = [inner_w - Theme.visible_len(title), 0].max
          fill       = paint(sep * fill_len, :accent)
          top_line   = "#{border}#{bg}#{tl}#{Theme::RESET}#{title_str}#{fill}#{border}#{bg}#{tr}#{Theme::RESET}"
          @screen.write(left_col, top_row, top_line)
        end

        def render_palette_entries(entries, left_col, top_row, inner_w, vert, bg, border)
          prefix = @suggestion_prefix.to_s
          entries.each_with_index do |entry, i|
            row = top_row + 1 + i
            render_palette_entry(entry, row, left_col, inner_w, vert, bg, border, prefix)
          end
        end

        def render_palette_entry(entry, row, left_col, inner_w, vert, bg, border, prefix) # rubocop:disable Metrics/ParameterLists
          cmd      = entry.is_a?(Hash) ? entry[:command].to_s : entry.to_s
          desc     = entry.is_a?(Hash) ? entry[:description].to_s : ""
          cmd_col  = 18
          desc_max = [inner_w - cmd_col - 3, 10].max

          cmd_display = build_palette_cmd_display(cmd, prefix)

          desc_trimmed = desc.length > desc_max ? "#{desc[0, desc_max - 1]}…" : desc
          desc_display = paint(desc_trimmed, :muted)
          gap          = " " * [cmd_col - Theme.visible_len(cmd), 1].max
          dot          = paint(Theme.utf8_capable? ? "·" : ".", :accent)

          content_vis = Theme.visible_len("  #{cmd}#{gap}#{dot} #{desc_trimmed}  ")
          rpad        = " " * [inner_w - content_vis, 0].max
          row_str = "#{border}#{bg}#{vert}#{Theme::RESET}" \
                    "#{bg}  #{cmd_display}#{gap}#{dot} #{desc_display}#{rpad}" \
                    "#{border}#{bg}#{vert}#{Theme::RESET}"
          @screen.write(left_col, row, row_str)
        end

        def build_palette_cmd_display(cmd, prefix)
          if prefix.length.positive? && cmd.start_with?(prefix)
            paint(cmd[0, prefix.length], :accent, :bold) +
              paint(cmd[prefix.length..] || "", :muted)
          else
            paint(cmd, :muted)
          end
        end

        def render_palette_bottom_border(left_col, top_row, palette_h, inner_w, bl, br, sep, bg, border) # rubocop:disable Metrics/ParameterLists
          bot_fill = paint(sep * inner_w, :accent)
          bot_line = "#{border}#{bg}#{bl}#{Theme::RESET}#{bot_fill}#{border}#{bg}#{br}#{Theme::RESET}"
          @screen.write(left_col, top_row + palette_h - 1, bot_line)
        end

        # ── Input Line ──────────────────────────────────────────────

        def render_input_line_frame
          sep_row   = @layout.separator_row
          input_row = @layout.input_row
          w         = @layout.term_width

          @screen.clear_row(sep_row)
          @screen.write(1, sep_row, paint(horizontal_rule(Theme.separator_char, w), :muted))

          @screen.clear_row(input_row)
          render_input_content_to_screen(input_row)
        end

        def render_input_content_to_screen(input_row)
          buf = @input_buffer
          if buf.nil? || buf.to_s.empty?
            render_empty_prompt_to_screen(input_row)
          else
            render_active_input_to_screen(buf, input_row)
          end
        end

        def render_empty_prompt_to_screen(input_row)
          bg      = Theme.ansi_for(:bg_input)
          prompt  = "#{bg}#{paint(Theme.prompt_char, :accent, :bold)} "
          content = prompt + paint("Type a message...", :muted) + Theme::RESET
          @screen.write(1, input_row, content)
          @screen.set_cursor(1 + visible_len("#{Theme.prompt_char} "), input_row)
        end

        def render_active_input_to_screen(buf, input_row)
          text           = normalize_terminal_text(buf.to_s)
          cursor         = buf.respond_to?(:cursor) ? buf.cursor : text.length
          bg             = Theme.ansi_for(:bg_input)
          prompt         = "#{bg}#{paint(Theme.prompt_char, :accent, :bold)} "
          prompt_len     = visible_len("#{Theme.prompt_char} ")
          w              = @layout.term_width
          char_count_str = text.length > 100 ? " #{text.length} chars" : ""
          char_count_len = char_count_str.length

          content = if char_count_len.positive? && (prompt_len + visible_len(text) + char_count_len <= w)
                      build_input_with_char_count(prompt, text, prompt_len, char_count_str, char_count_len, w)
                    else
                      "#{prompt}#{text}#{Theme::RESET}"
                    end
          @screen.write(1, input_row, content)
          col = 1 + prompt_len + visible_len(text[0, cursor].to_s)
          @screen.set_cursor(col, input_row)
        end

        def build_input_with_char_count(prompt, text, prompt_len, char_count_str, char_count_len, w)
          text_len = visible_len(text)
          pad      = [w - prompt_len - text_len - char_count_len, 0].max
          "#{prompt}#{text}#{" " * pad}#{paint(char_count_str, :muted)}#{Theme::RESET}"
        end

        def horizontal_rule(char = Theme.separator_char, width = nil)
          width ||= (@layout ? @layout.term_width : 80)
          char * width
        end
      end
    end
  end
end
