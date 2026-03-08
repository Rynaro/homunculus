# frozen_string_literal: true

module Homunculus
  module Interfaces
    class TUI
      # Braille spinner for status bar. Runs in a dedicated thread, invokes
      # redraw callback every ~100ms so the TUI can show frame + message.
      class ActivityIndicator
        FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
        FRAME_COUNT = 8
        TICK_MS = 180
        JOIN_TIMEOUT = 0.5

        attr_reader :message

        def initialize(redraw:)
          @message     = ""
          @running     = false
          @frame_index = 0
          @redraw      = redraw
          @thread      = nil
        end

        def start(message)
          @message = message.to_s
          @running = true
          @frame_index = 0
          @thread = Thread.new { run_loop }
        end

        def update(message)
          @message = message.to_s
        end

        def stop
          @running = false
          return unless @thread&.alive?

          @thread.join(JOIN_TIMEOUT)
          @thread = nil
        end

        def running?
          @running
        end

        def frame_char
          FRAMES[@frame_index % FRAME_COUNT]
        end

        private

        def run_loop
          while @running
            @frame_index = (@frame_index + 1) % FRAME_COUNT
            @redraw&.call
            sleep(TICK_MS / 1000.0)
          end
        end
      end
    end
  end
end
