# frozen_string_literal: true

module Homunculus
  module Interfaces
    class TUI
      # Virtual 2D cell grid. Each cell holds {char, fg, bg, bold, dim, italic, underline}.
      # flush(io) diffs current vs previous frame and emits a single atomic write.
      # force_flush(io) redraws everything unconditionally (resize / initial render).
      class ScreenBuffer
        Cell = Struct.new(:char, :fg, :bg, :bold, :dim, :italic, :underline) do
          def ==(other)
            char == other.char && fg == other.fg && bg == other.bg &&
              bold == other.bold && dim == other.dim &&
              italic == other.italic && underline == other.underline
          end
        end

        BLANK_CELL = Cell.new(char: " ", fg: nil, bg: nil, bold: false, dim: false,
                              italic: false, underline: false).freeze

        attr_reader :rows, :cols

        def initialize(rows, cols)
          @rows = rows
          @cols = cols
          @current  = build_grid(rows, cols)
          @previous = build_grid(rows, cols)
          @dirty    = Array.new(rows, false)
          @cursor_row = 1
          @cursor_col = 1
        end

        # Resize the buffer to new dimensions. Content is cleared.
        def resize(rows, cols)
          @rows = rows
          @cols = cols
          @current  = build_grid(rows, cols)
          @previous = build_grid(rows, cols)
          @dirty    = Array.new(rows, false)
        end

        # Write +text+ starting at (col, row) — 1-based.
        # Parses embedded ANSI SGR sequences and maps them to cell attributes.
        def write(col, row, text)
          return unless in_bounds_row?(row)

          cells = ANSIParser.parse(text)
          c = col - 1
          cells.each do |cell|
            break if c >= @cols

            @current[row - 1][c] = cell if c >= 0
            c += 1
          end
          @dirty[row - 1] = true
        end

        # Fill an entire row with blanks (clear it).
        def clear_row(row)
          return unless in_bounds_row?(row)

          @current[row - 1] = Array.new(@cols) { BLANK_CELL.dup }
          @dirty[row - 1] = true
        end

        # Clear all rows.
        def clear
          @current = build_grid(@rows, @cols)
        end

        # Move the logical cursor position (used when computing final cursor placement).
        def set_cursor(col, row)
          @cursor_row = row
          @cursor_col = col
          @dirty[row - 1] = true if in_bounds_row?(row)
        end

        # Diff current vs previous frame; emit minimal escape sequences in one write.
        # Only iterates dirty rows — rows untouched since last flush are skipped entirely.
        def flush(io)
          return unless @dirty.any?

          buf = +""
          last_row = nil
          last_col = nil
          terminal_style = BLANK_CELL

          @dirty.each_with_index do |dirty, r|
            next unless dirty

            @cols.times do |c|
              cur  = @current[r][c]
              prev = @previous[r][c]
              next if cur == prev

              # Move if not adjacent
              buf << "\e[#{r + 1};#{c + 1}H" if last_row != r + 1 || last_col != c + 1

              buf << cell_escape(cur, terminal_style)
              buf << cur.char
              terminal_style = cur
              last_row = r + 1
              last_col = c + 2

              # Inline copy — no separate pass needed
              prev.char      = cur.char
              prev.fg        = cur.fg
              prev.bg        = cur.bg
              prev.bold      = cur.bold
              prev.dim       = cur.dim
              prev.italic    = cur.italic
              prev.underline = cur.underline
            end
          end

          buf << "\e[0m" unless buf.empty?
          buf << "\e[#{@cursor_row};#{@cursor_col}H"
          buf << "\e[?25h"

          io.write(buf)
          io.flush
          @dirty.fill(false)
        end

        # Full redraw — emit every cell unconditionally (resize / initial render).
        # Uses per-cell absolute positioning to avoid wide-character column drift.
        def force_flush(io)
          buf = +""
          buf << "\e[2J\e[H"
          terminal_style = BLANK_CELL
          last_row = nil
          last_col = nil

          @rows.times do |r|
            @cols.times do |c|
              cur = @current[r][c]

              buf << "\e[#{r + 1};#{c + 1}H" if last_row != r + 1 || last_col != c + 1
              buf << cell_escape(cur, terminal_style)
              buf << cur.char
              terminal_style = cur
              last_row = r + 1
              last_col = c + 2

              # Inline copy
              prev = @previous[r][c]
              prev.char      = cur.char
              prev.fg        = cur.fg
              prev.bg        = cur.bg
              prev.bold      = cur.bold
              prev.dim       = cur.dim
              prev.italic    = cur.italic
              prev.underline = cur.underline
            end
          end

          buf << "\e[0m"
          buf << "\e[#{@cursor_row};#{@cursor_col}H"
          buf << "\e[?25h"

          io.write(buf)
          io.flush
          @dirty.fill(false)
        end

        private

        def build_grid(rows, cols)
          Array.new(rows) { Array.new(cols) { BLANK_CELL.dup } }
        end

        def in_bounds_row?(row)
          row.between?(1, @rows)
        end

        def cell_escape(cur, prev)
          codes = style_needs_reset?(cur, prev) ? reset_style_codes(cur) : delta_style_codes(cur, prev)
          codes.empty? ? "" : "\e[#{codes.join(";")}m"
        end

        def style_needs_reset?(cur, prev)
          (prev.bold && !cur.bold) || (prev.dim && !cur.dim) ||
            (prev.italic && !cur.italic) || (prev.underline && !cur.underline) ||
            (!cur.fg && prev.fg) || (!cur.bg && prev.bg)
        end

        def reset_style_codes(cur)
          codes = [0]
          codes << 1 if cur.bold
          codes << 2 if cur.dim
          codes << 3 if cur.italic
          codes << 4 if cur.underline
          codes << fg_code(cur.fg) if cur.fg
          codes << bg_code(cur.bg) if cur.bg
          codes
        end

        def delta_style_codes(cur, prev)
          codes = []
          codes << 1 if cur.bold && !prev.bold
          codes << 2 if cur.dim && !prev.dim
          codes << 3 if cur.italic && !prev.italic
          codes << 4 if cur.underline && !prev.underline
          codes << fg_code(cur.fg) if cur.fg && cur.fg != prev.fg
          codes << bg_code(cur.bg) if cur.bg && cur.bg != prev.bg
          codes
        end

        def fg_code(color_escape)
          # Extract the numeric part from "\e[38;5;75m" or "\e[32m" etc.
          return nil unless color_escape

          m = color_escape.match(/\e\[([0-9;]+)m/)
          m ? m[1] : nil
        end

        def bg_code(color_escape)
          return nil unless color_escape

          m = color_escape.match(/\e\[([0-9;]+)m/)
          m ? m[1] : nil
        end
      end
    end
  end
end
