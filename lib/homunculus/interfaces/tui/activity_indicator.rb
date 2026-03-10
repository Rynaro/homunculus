# frozen_string_literal: true

module Homunculus
  module Interfaces
    class TUI
      # Braille spinner for status bar. Runs in a dedicated thread, invokes
      # redraw callback every ~100ms so the TUI can show frame + message.
      class ActivityIndicator
        FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
        FRAME_COUNT = FRAMES.length
        TICK_MS = 180
        JOIN_TIMEOUT = 0.5

        def initialize(redraw:)
          @message = ""
          @running = false
          @frame_index = 0
          @redraw = redraw
          @thread = nil
          @mutex = Mutex.new
        end

        def start(message)
          stop

          @mutex.synchronize do
            @message = message.to_s
            @running = true
            @frame_index = 0
            @thread = Thread.new { run_loop }
          end
        end

        def update(message)
          @mutex.synchronize do
            @message = message.to_s
          end
        end

        def stop
          thread = @mutex.synchronize do
            @running = false
            current = @thread
            @thread = nil
            current
          end
          return unless thread&.alive?

          thread.join(JOIN_TIMEOUT)
        end

        def running?
          @mutex.synchronize { @running }
        end

        def message
          @mutex.synchronize { @message.dup }
        end

        def frame_char
          @mutex.synchronize { FRAMES[@frame_index % FRAME_COUNT] }
        end

        def snapshot
          @mutex.synchronize do
            {
              running: @running,
              message: @message.dup,
              frame_char: FRAMES[@frame_index % FRAME_COUNT]
            }
          end
        end

        private

        def run_loop
          while running?
            @mutex.synchronize do
              @frame_index = (@frame_index + 1) % FRAME_COUNT
            end
            @redraw&.call
            sleep(TICK_MS / 1000.0)
          end
        end
      end
    end
  end
end
