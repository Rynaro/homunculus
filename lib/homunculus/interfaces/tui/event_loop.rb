# frozen_string_literal: true

module Homunculus
  module Interfaces
    class TUI
      # Single-threaded event loop for the TUI. All rendering happens here —
      # eliminating concurrent stdout writes.
      #
      # Event types (pushed to @queue):
      #   { type: :keypress,      event: <hash from KeyboardReader> }
      #   { type: :stream_chunk,  chunk: String }
      #   { type: :spinner_tick }
      #   { type: :resize,        width: Integer, height: Integer }
      #   { type: :agent_result,  result: <AgentLoop result> }
      #   { type: :notification,  text: String }
      #   { type: :refresh }
      #   { type: :shutdown }
      #
      # The loop drains the queue, applies all pending state updates, then
      # renders exactly one frame per iteration (60fps cap).
      class EventLoop
        FRAME_PERIOD = 1.0 / 60 # ~16ms

        attr_reader :queue

        def initialize(render_fn:)
          @queue     = Thread::Queue.new
          @render_fn = render_fn
          @running   = false
          @thread    = nil
        end

        # Push any event hash into the queue (thread-safe).
        def push(event)
          @queue << event
        end

        # Start the event loop in the current thread.
        # Blocks until a :shutdown event is received or stop is called.
        def run
          @running = true
          loop_body
        end

        # Start the loop in a background thread.
        def start
          @running = true
          @thread = Thread.new { loop_body }
          @thread.abort_on_exception = false
        end

        def stop
          @running = false
          @queue << { type: :shutdown }
          @thread&.join(0.5)
          @thread = nil
        end

        def running?
          @running
        end

        private

        def loop_body
          pending_events = []
          last_render = Time.now

          while @running
            # Drain all currently queued events (non-blocking after first)
            drain_events(pending_events)

            # Check for shutdown — set @running so running? reflects state immediately
            if pending_events.any? { |e| e[:type] == :shutdown }
              @running = false
              break
            end

            # Deliver events to render function
            @render_fn.call(pending_events) unless pending_events.empty?
            pending_events.clear

            # Rate-limit to ~60fps
            elapsed = Time.now - last_render
            sleep_time = FRAME_PERIOD - elapsed
            sleep(sleep_time) if sleep_time.positive?
            last_render = Time.now
          end
        rescue StandardError
          # Loop exit
        end

        def drain_events(accumulator)
          # Block briefly waiting for the first event
          begin
            first = @queue.pop(true)
            accumulator << first
          rescue ThreadError
            # Queue empty — sleep briefly then try once more
            sleep(0.005)
            begin
              first = @queue.pop(true)
              accumulator << first
            rescue ThreadError
              return
            end
          end

          # Drain remaining without blocking
          loop do
            accumulator << @queue.pop(true)
          rescue ThreadError
            break
          end
        end
      end
    end
  end
end
