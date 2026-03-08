# frozen_string_literal: true

module Homunculus
  module Interfaces
    class TUI
      # Cursor-aware line buffer for TUI input. Cursor is always in 0..buf.length.
      class InputBuffer
        attr_reader :cursor

        def initialize
          @buf    = +""
          @cursor = 0
        end

        def insert(char)
          return if char.nil? || char.to_s.empty?

          c = char.to_s
          @buf.insert(@cursor, c)
          @cursor = clamp_cursor(@cursor + c.length)
        end

        def backspace
          return if @cursor <= 0

          @buf.slice!(@cursor - 1)
          @cursor = clamp_cursor(@cursor - 1)
        end

        def delete
          return if @cursor >= @buf.length

          @buf.slice!(@cursor)
        end

        def move_left
          @cursor = clamp_cursor(@cursor - 1)
        end

        def move_right
          @cursor = clamp_cursor(@cursor + 1)
        end

        def move_home
          @cursor = 0
        end

        def move_end
          @cursor = @buf.length
        end

        def move_word_left
          return move_home if @cursor <= 0

          # Skip spaces left of cursor, then skip word chars
          i = @cursor - 1
          i -= 1 while i >= 0 && @buf[i] =~ /\s/
          i -= 1 while i >= 0 && @buf[i] !~ /\s/
          @cursor = i.negative? ? 0 : i + 1
        end

        def move_word_right
          return move_end if @cursor >= @buf.length

          # Skip spaces, then skip word chars
          i = @cursor
          i += 1 while i < @buf.length && @buf[i] =~ /\s/
          i += 1 while i < @buf.length && @buf[i] !~ /\s/
          @cursor = i
        end

        # Delete from cursor back to last space or start (Ctrl+W).
        def delete_word_backward
          return if @cursor <= 0

          start = @cursor - 1
          start -= 1 while start >= 0 && @buf[start] =~ /\s/
          start -= 1 while start >= 0 && @buf[start] !~ /\s/
          start += 1
          start = 0 if start.negative?
          @buf.slice!(start...@cursor)
          @cursor = start
        end

        def to_s
          @buf.to_s
        end

        def clear
          @buf = +""
          @cursor = 0
        end

        private

        def clamp_cursor(pos)
          pos.clamp(0, @buf.length)
        end
      end
    end
  end
end
