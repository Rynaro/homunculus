# frozen_string_literal: true

module Homunculus
  module Interfaces
    class TUI
      # Parses a string containing ANSI SGR escape sequences into an array of
      # ScreenBuffer::Cell objects. One cell per visible character.
      module ANSIParser
        # Matches ESC [ ... m sequences
        SGR_RE = /\e\[([0-9;]*)m/

        def self.parse(text)
          cells = []
          state = fresh_state

          i = 0
          chars = text.to_s.chars
          while i < chars.length
            ch = chars[i]

            if ch == "\e" && chars[i + 1] == "["
              # Scan to end of escape sequence
              j = i + 2
              j += 1 while j < chars.length && chars[j] != "m" && !chars[j].match?(/[A-Za-z]/)
              seq_end = j
              full_seq = chars[i..seq_end].join
              m = full_seq.match(SGR_RE)
              apply_sgr(state, m[1]) if m
              i = seq_end + 1
            elsif ch.ord >= 32 || ch == "\t"
              cells << ScreenBuffer::Cell.new(
                char: ch == "\t" ? " " : ch,
                fg: state[:fg],
                bg: state[:bg],
                bold: state[:bold],
                dim: state[:dim],
                italic: state[:italic],
                underline: state[:underline]
              )
              i += 1
            else
              i += 1
            end
          end

          cells
        end

        def self.fresh_state
          { fg: nil, bg: nil, bold: false, dim: false, italic: false, underline: false }
        end

        # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
        def self.apply_sgr(state, params)
          codes = params.split(";").map(&:to_i)
          codes = [0] if codes.empty?

          i = 0
          while i < codes.length
            code = codes[i]
            case code
            when 0
              state[:fg] = nil
              state[:bg] = nil
              state[:bold] = false
              state[:dim] = false
              state[:italic] = false
              state[:underline] = false
            when 1 then state[:bold] = true
            when 2 then state[:dim] = true
            when 3 then state[:italic] = true
            when 4 then state[:underline] = true
            when 22 then state[:bold] = false; state[:dim] = false # rubocop:disable Style/Semicolon
            when 23 then state[:italic] = false
            when 24 then state[:underline] = false
            when 30..37 then state[:fg] = "\e[#{code}m"
            when 38
              if codes[i + 1] == 5 && codes[i + 2]
                state[:fg] = "\e[38;5;#{codes[i + 2]}m"
                i += 2
              elsif codes[i + 1] == 2 && codes[i + 3]
                state[:fg] = "\e[38;2;#{codes[i + 2]};#{codes[i + 3]};#{codes[i + 4]}m"
                i += 4
              end
            when 39 then state[:fg] = nil
            when 40..47 then state[:bg] = "\e[#{code}m"
            when 48
              if codes[i + 1] == 5 && codes[i + 2]
                state[:bg] = "\e[48;5;#{codes[i + 2]}m"
                i += 2
              end
            when 49 then state[:bg] = nil
            end
            i += 1
          end
        end
        # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity
      end
    end
  end
end
