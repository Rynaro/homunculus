# frozen_string_literal: true

require_relative "theme"

module Homunculus
  module Interfaces
    class TUI
      # Renders chat message hashes into styled terminal lines. Supports markdown
      # (bold, italic, code, lists, headings) for assistant messages only.
      class MessageRenderer
        include TUI::Theme

        ANSI_WRAPPED_TOKEN = /\A((?:\e\[[0-9;]*m)+)(.*?)(\e\[0m)\z/m

        def initialize(width:, agent_name: TUI::AGENT_NAME)
          @width = width
          @agent_name = agent_name
        end

        def render(msg)
          role = msg[:role]
          return render_tool_card(msg) if role == :tool_request

          text = msg[:text].to_s
          label = role_label(role)
          color = role_style(role)
          timestamp_plain = msg[:timestamp] ? msg[:timestamp].strftime("[%H:%M] ") : ""
          prefix_plain = "#{timestamp_plain}#{role_indicator(role)} #{label}: "
          indent = " " * Theme.visible_len(prefix_plain)

          if role == :assistant && !text.empty?
            render_with_markdown(text, prefix_plain, indent, color)
          else
            render_plain(text, prefix_plain, indent, color)
          end
        end

        private

        def role_label(role)
          case role
          when :user      then "You"
          when :assistant then @agent_name
          when :system    then "System"
          when :error     then "Error"
          when :tool_request then "Tool"
          else role.to_s.capitalize
          end
        end

        def role_indicator(role)
          case role
          when :user      then Theme::ROLE_USER
          when :assistant then Theme::ROLE_ASSISTANT
          when :info      then Theme::ROLE_INFO
          when :error     then Theme::ROLE_ERROR
          else                 Theme::ROLE_INFO
          end
        end

        def role_style(role)
          case role
          when :user      then :user
          when :assistant then :assistant
          when :system    then :accent
          when :error     then :error
          when :info      then :info
          when :tool_request then :accent
          else :muted
          end
        end

        def render_tool_card(msg)
          name = msg[:tool_name].to_s
          args = msg[:arguments] || {}
          w = @width
          border_char = "─"
          inner_w = [w - 4, 10].max
          title = " Tool Request "
          top_inner = "#{title}#{border_char * [w - title.length - 2, 0].max}"
          top = "┌#{top_inner[0, w - 2].ljust(w - 2, border_char)}┐"
          bottom = "└#{border_char * (w - 2)}┘"
          body = wrap_card_text(name, inner_w)
          args.each do |k, v|
            body.concat(wrap_card_text("#{k}: #{v.inspect}", inner_w))
          end
          body << ""
          body.concat(wrap_card_text("◈ Requires confirmation", inner_w))
          body.concat(wrap_card_text("Type /confirm or /deny", inner_w))

          lines = [Theme.paint(top, :accent)]
          body.each do |line|
            lines << Theme.paint("│ #{line.ljust(inner_w)} │", :accent)
          end
          lines << Theme.paint(bottom, :accent)
          lines
        end

        def render_plain(text, prefix_plain, indent, color)
          out = []

          text.to_s.split("\n", -1).each do |line|
            prefix = out.empty? ? prefix_plain : indent
            wrapped = wrap_prefixed_text(
              line,
              prefix:,
              continuation: indent,
              preserve_leading_space: false,
              strip_trailing: true
            )
            wrapped.each do |wrapped_line|
              out << paint_role_line(wrapped_line, color, out.empty?)
            end
          end

          out.empty? ? [paint_role_line(prefix_plain, color, true)] : out
        end

        def render_with_markdown(text, prefix_plain, indent, color)
          segments = split_code_blocks(text)
          out = []

          segments.each do |seg|
            if seg[:type] == :code
              block = seg[:content].sub(/\A\r?\n/, "")
              block_lines = block.split("\n", -1)
              block_lines.shift if block_lines.length > 1 && block_lines.first.to_s.match?(/\A\w+\s*\z/)
              block_lines.each do |line|
                prefix = out.empty? ? prefix_plain : indent
                wrapped = wrap_prefixed_text(
                  "  #{line}",
                  prefix:,
                  continuation: indent,
                  preserve_leading_space: true,
                  strip_trailing: false
                )
                wrapped.each_with_index do |wrapped_line, index|
                  current_prefix = index.zero? ? prefix : indent
                  code_content = wrapped_line[current_prefix.length..] || ""
                  prefix_text = out.empty? && index.zero? ? paint_role_line(current_prefix, color, true) : current_prefix
                  out << "#{prefix_text}#{Theme.paint(code_content, :warm_highlight)}"
                end
              end
            else
              expanded = apply_inline_markdown(seg[:content])
              expanded.split("\n", -1).each do |line|
                prefix = out.empty? ? prefix_plain : indent
                wrapped = wrap_prefixed_text(
                  line,
                  prefix:,
                  continuation: indent,
                  preserve_leading_space: false,
                  strip_trailing: true
                )
                wrapped.each do |wrapped_line|
                  out << paint_role_line(wrapped_line, color, out.empty?)
                end
              end
            end
          end

          out = [paint_role_line(prefix_plain, color, true)] if out.empty?
          out
        end

        def split_code_blocks(text)
          result = []
          rest = text
          until rest.empty?
            idx = rest.index("```")
            unless idx
              result << { type: :text, content: rest }
              break
            end
            result << { type: :text, content: rest[0...idx] } if idx.positive?
            rest = rest[(idx + 3)..] || ""
            end_idx = rest.index("```")
            unless end_idx
              result << { type: :text, content: "```#{rest}" }
              break
            end
            result << { type: :code, content: rest[0...end_idx] }
            rest = rest[(end_idx + 3)..] || ""
          end
          result
        end

        def apply_inline_markdown(segment)
          # Process by lines to handle lists and headings
          segment.split("\n").map do |line|
            line = apply_heading(line)
            line = apply_list_line(line)
            apply_inline_formatting(line)
          end.join("\n")
        end

        def apply_heading(line)
          return line unless line.match(/\A#+\s+/)

          m = line.match(/\A(#+)\s+(.*)/)
          return line unless m

          rest = m[2]
          Theme.paint(rest, :bold)
        end

        def apply_list_line(line)
          line = line.sub(/\A(\s*)[-*](\s+)/, "\\1#{Theme::BULLET_CHAR}\\2") if line.match(/\A\s*[-*]\s+/)
          line
        end

        def apply_inline_formatting(line)
          # Inline code: `...` -> warm_highlight (non-greedy)
          line = line.gsub(/`([^`]+)`/) { Theme.paint(::Regexp.last_match(1), :warm_highlight) }
          # Bold: **x** or __x__
          line = line.gsub(/\*\*(.+?)\*\*/) { Theme.paint(::Regexp.last_match(1), :bold) }
          line = line.gsub(/__(.+?)__/) { Theme.paint(::Regexp.last_match(1), :bold) }
          # Italic: *x* or _x_ (single; avoid breaking **)
          line = line.gsub(/(?<!\*)\*([^*]+)\*(?!\*)/) { Theme.paint(::Regexp.last_match(1), :italic) }
          line.gsub(/(?<!_)_([^_]+)_(?!_)/) { Theme.paint(::Regexp.last_match(1), :italic) }
        end

        def wrap_styled_text(styled_str, indent_len)
          wrap_prefixed_text(
            styled_str,
            prefix: "",
            continuation: "",
            preserve_leading_space: false,
            strip_trailing: true
          ).map { |line| line[indent_len..] || "" }
        end

        def wrap_card_text(text, width)
          prev_width = @width
          @width = width
          wrap_prefixed_text(
            text.to_s,
            prefix: "",
            continuation: "",
            preserve_leading_space: true,
            strip_trailing: false
          )
        ensure
          @width = prev_width
        end

        def wrap_prefixed_text(text, prefix:, continuation:, preserve_leading_space:, strip_trailing:)
          tokens = text.to_s.gsub("\t", "  ").scan(/\s+|\S+/)
          return [prefix.dup] if tokens.empty?

          lines = []
          current = prefix.dup

          tokens.each do |token|
            pending = token.dup
            while pending && !pending.empty?
              break if whitespace_token?(pending) && !preserve_leading_space &&
                       empty_content_line?(current, prefix, continuation)

              remaining = [@width - Theme.visible_len(current), 1].max
              piece, pending = take_visible_prefix(pending, remaining)
              next if piece.empty?

              next if whitespace_token?(piece) && !preserve_leading_space &&
                      empty_content_line?(current, prefix, continuation)

              current << piece

              next unless !pending.empty? || Theme.visible_len(current) >= @width

              lines << finalize_wrapped_line(current, prefix:, continuation:, strip_trailing:)
              current = continuation.dup
            end
          end

          unless current == continuation && lines.any?
            lines << finalize_wrapped_line(current, prefix:, continuation:, strip_trailing:)
          end
          lines
        end

        def take_visible_prefix(token, max_visible)
          return [token, ""] if Theme.visible_len(token) <= max_visible

          if (match = token.match(ANSI_WRAPPED_TOKEN))
            prefix, content, suffix = match.captures
            left, right = split_plain_text(content, max_visible)
            return ["#{prefix}#{left}#{suffix}", right.empty? ? "" : "#{prefix}#{right}#{suffix}"]
          end

          split_plain_text(token, max_visible)
        end

        def split_plain_text(text, max_visible)
          visible = 0
          left = +""
          right = +""
          text.each_char do |char|
            if visible < max_visible
              left << char
              visible += 1
            else
              right << char
            end
          end
          [left, right]
        end

        def finalize_wrapped_line(line, prefix:, continuation:, strip_trailing:)
          return line unless strip_trailing
          return prefix.dup if line == prefix
          return continuation.dup if line == continuation

          trimmed = line.rstrip
          trimmed.empty? ? continuation.dup : trimmed
        end

        def whitespace_token?(token)
          token.match?(/\A\s+\z/)
        end

        def empty_content_line?(line, prefix, continuation)
          line == prefix || line == continuation
        end

        def paint_role_line(line, color, is_label_line)
          return line if line.strip.empty?

          if is_label_line
            ts_match = line.match(/\A(\[\d{2}:\d{2}\] )/)
            if ts_match
              ts_prefix = ts_match[1]
              return Theme.paint(ts_prefix, :muted) + paint_role_line(line[ts_prefix.length..], color, true)
            end
            label_end = line.index(": ")
            if label_end
              label_part = line[0..(label_end + 1)]
              rest_part = line[(label_end + 2)..]
              return Theme.paint(label_part, color,
                                 :bold) + (rest_part.to_s.include?("\e[") ? rest_part.to_s : Theme.paint(rest_part.to_s, :reset))
            end
            Theme.paint(line, color)
          else
            line.include?("\e[") ? line : Theme.paint(line, :reset)
          end
        end
      end
    end
  end
end
