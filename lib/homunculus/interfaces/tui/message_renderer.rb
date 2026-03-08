# frozen_string_literal: true

require_relative "theme"

module Homunculus
  module Interfaces
    class TUI
      # Renders chat message hashes into styled terminal lines. Supports markdown
      # (bold, italic, code, lists, headings) for assistant messages only.
      class MessageRenderer
        include TUI::Theme

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
          else                 role.to_s.capitalize
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
          else                 :muted
          end
        end

        def render_tool_card(msg)
          name = msg[:tool_name].to_s
          args = msg[:arguments] || {}
          w = @width
          border_char = "─"
          inner_w = [w - 4, 10].max
          top = "┌─ Tool Request #{border_char * [w - 18, 1].max}┐"[0, w]
          bottom = "└#{border_char * (w - 2)}┘"
          lines = [
            Theme.paint(top, :accent),
            Theme.paint("│  #{name.to_s[0, inner_w].ljust(inner_w)}│", :accent)
          ]
          args.each do |k, v|
            arg_line = "#{k}: #{v.inspect}"
            arg_line = arg_line[0, inner_w] if arg_line.length > inner_w
            lines << Theme.paint("│  #{arg_line.ljust(inner_w)}│", :accent)
          end
          lines << Theme.paint("│#{' ' * (w - 2)}│", :accent)
          hint1 = "  ◈ Requires confirmation"
          hint2 = "  Type /confirm or /deny"
          lines << Theme.paint("│#{hint1.to_s[0, w - 2].ljust(w - 2)}│", :accent)
          lines << Theme.paint("│#{hint2.to_s[0, w - 2].ljust(w - 2)}│", :accent)
          lines << Theme.paint(bottom, :accent)
          lines
        end

        def render_plain(text, prefix_plain, indent, color)
          lines = []
          text.split("\n").each_with_index do |para, para_idx|
            words = para.split
            current_line = para_idx.zero? ? prefix_plain : indent
            words.each do |word|
              if Theme.visible_len(current_line) + word.length + 1 > @width
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

        def render_with_markdown(text, prefix_plain, indent, color)
          segments = split_code_blocks(text)
          out = []
          first_line = true
          prefix_len = Theme.visible_len(prefix_plain)
          indent_len = Theme.visible_len(indent)

          segments.each do |seg|
            if seg[:type] == :code
              block_lines = seg[:content].strip.split("\n")
              block_lines.shift if block_lines.first.to_s.match(/\A\w+\s*\z/)
              block_lines.each do |line|
                styled = Theme.paint("  #{line}", :warm_highlight)
                out << (first_line ? paint_role_line(prefix_plain, color, true).sub(/: \z/, ": ") + styled : indent + styled)
                first_line = false
              end
            else
              expanded = apply_inline_markdown(seg[:content])
              wrapped = wrap_styled_text(expanded, first_line ? prefix_len : indent_len)
              wrapped.each_with_index do |line_plain, i|
                line_with_prefix = first_line && i.zero? ? prefix_plain + line_plain : indent + line_plain
                out << paint_role_line(line_with_prefix, color, first_line && i.zero?)
                first_line = false
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
              result << { type: :text, content: "```" + rest }
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
          if line.match(/\A\s*[-*]\s+/)
            line = line.sub(/\A(\s*)[-*](\s+)/, "\\1#{Theme::BULLET_CHAR}\\2")
          end
          line
        end

        def apply_inline_formatting(line)
          # Inline code: `...` -> warm_highlight (non-greedy)
          line = line.gsub(/`([^`]+)`/) { Theme.paint($1, :warm_highlight) }
          # Bold: **x** or __x__
          line = line.gsub(/\*\*(.+?)\*\*/) { Theme.paint($1, :bold) }
          line = line.gsub(/__(.+?)__/) { Theme.paint($1, :bold) }
          # Italic: *x* or _x_ (single; avoid breaking **)
          line = line.gsub(/(?<!\*)\*([^*]+)\*(?!\*)/) { Theme.paint($1, :italic) }
          line = line.gsub(/(?<!_)_([^_]+)_(?!_)/) { Theme.paint($1, :italic) }
          line
        end

        def wrap_styled_text(styled_str, indent_len)
          words = styled_str.split(/(\s+)/)
          lines = []
          current = +""
          current_len = 0
          max_len = @width - indent_len

          words.each do |w|
            wlen = Theme.visible_len(w)
            if current_len + wlen > max_len && !current.empty?
              lines << current
              current = w
              current_len = wlen
            else
              current << w
              current_len += wlen
            end
          end
          lines << current unless current.empty?
          lines
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
              return Theme.paint(label_part, color, :bold) + (rest_part.to_s.include?("\e[") ? rest_part.to_s : Theme.paint(rest_part.to_s, :reset))
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
