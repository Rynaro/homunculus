# frozen_string_literal: true

module Homunculus
  module Interfaces
    class TUI
      # Computes region boundaries for the TUI layout.
      #
      # Layout (rows are 1-based):
      #   Row 1          — header top rule
      #   Row 2          — header title / date
      #   Row 3          — header tagline / bottom rule
      #   Rows 4..N      — chat panel (scrollable)
      #   Row N+1        — status bar
      #   Row N+2        — separator
      #   Row N+3..N+end — input area (suggestions + input line)
      #
      # The layout deliberately uses the full terminal width for content to avoid
      # the previous `inner_width = term_width - 2` bottleneck. Aesthetic margins
      # are applied in the renderers themselves.
      class Layout
        HEADER_ROWS = 3
        STATUS_ROWS = 1
        SEPARATOR_ROWS = 1
        INPUT_ROWS = 1
        MIN_CHAT_ROWS = 4
        # How many rows above the input line are reserved for slash-command suggestions
        SUGGESTION_ROWS = 5

        attr_reader :term_width, :term_height

        def initialize(term_width:, term_height:)
          @term_width  = term_width
          @term_height = term_height
        end

        # Update dimensions (e.g. on SIGWINCH).
        def resize(term_width:, term_height:)
          @term_width  = term_width
          @term_height = term_height
        end

        # Total chrome (non-chat) rows.
        def chrome_rows
          HEADER_ROWS + STATUS_ROWS + SEPARATOR_ROWS + INPUT_ROWS
        end

        # Number of usable chat rows.
        # Suggestions overlay rather than reduce chat space.
        def chat_rows
          [term_height - chrome_rows, MIN_CHAT_ROWS].max
        end

        # Width available for chat content (aesthetic 1-char margin on each side).
        def chat_width
          [term_width - 2, 10].max
        end

        # 1-based row ranges for each region.

        def header_rows
          1..HEADER_ROWS
        end

        def chat_start_row
          HEADER_ROWS + 1
        end

        def chat_end_row
          chat_start_row + chat_rows - 1
        end

        def chat_region
          chat_start_row..chat_end_row
        end

        def status_row
          chat_end_row + 1
        end

        def separator_row
          status_row + 1
        end

        # First suggestion row (rows between separator and input line).
        def suggestion_start_row
          separator_row + 1
        end

        def input_row
          term_height
        end
      end
    end
  end
end
