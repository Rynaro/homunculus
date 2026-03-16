# frozen_string_literal: true

module Homunculus
  module Interfaces
    class TUI
      # Reads raw bytes from an IO object and emits semantic key events via a
      # Thread::Queue. Uses a proper escape-sequence state machine rather than
      # read_nonblock(8) heuristics.
      #
      # Supported events (pushed to queue as hashes):
      #   { type: :key, key: :enter }
      #   { type: :key, key: :backspace }
      #   { type: :key, key: :arrow_up }    # etc.
      #   { type: :key, key: :page_up }
      #   { type: :key, key: :ctrl_c }
      #   { type: :key, key: :ctrl_u }      # etc.
      #   { type: :char, char: "a" }        # printable character
      class KeyboardReader
        ESCAPE_TIMEOUT = 0.05 # seconds to wait for follow-on escape bytes

        ESCAPE_SEQUENCES = {
          "[A" => :arrow_up,
          "[B" => :arrow_down,
          "[C" => :arrow_right,
          "[D" => :arrow_left,
          "[H" => :home,
          "[F" => :end_key,
          "[1;2A" => :shift_up,
          "[1;2B" => :shift_down,
          "[1;5C" => :ctrl_right,
          "[1;5D" => :ctrl_left,
          "[5~" => :page_up,
          "[6~" => :page_down
        }.freeze

        def initialize(io, queue)
          @io    = io
          @queue = queue
          @running = false
          @thread  = nil
        end

        def start
          @running = true
          @thread = Thread.new { read_loop }
          @thread.abort_on_exception = false
        end

        def stop
          @running = false
          @thread&.join(0.2)
          @thread = nil
        end

        def running?
          @running
        end

        private

        def read_loop
          while @running
            byte = read_byte_with_timeout(0.05)
            next if byte.nil?

            process_byte(byte)
          end
        rescue StandardError
          # Thread exit — not an error
        end

        def process_byte(byte)
          case byte
          when "\r", "\n"
            @queue << { type: :key, key: :enter }
          when "\x03"
            @queue << { type: :key, key: :ctrl_c }
          when "\x01"
            @queue << { type: :key, key: :ctrl_a }
          when "\x05"
            @queue << { type: :key, key: :ctrl_e }
          when "\x0C"
            @queue << { type: :key, key: :ctrl_l }
          when "\x15"
            @queue << { type: :key, key: :ctrl_u }
          when "\x17"
            @queue << { type: :key, key: :ctrl_w }
          when "\t"
            @queue << { type: :key, key: :tab }
          when "\x7f", "\b"
            @queue << { type: :key, key: :backspace }
          when "\x1b"
            handle_escape
          else
            emit_char(byte)
          end
        end

        def handle_escape
          next_byte = read_byte_with_timeout(ESCAPE_TIMEOUT)
          if next_byte.nil?
            @queue << { type: :key, key: :escape }
            return
          end

          if next_byte == "["
            read_csi_sequence
          else
            # ESC + single char (Alt+key)
            @queue << { type: :key, key: :escape }
            emit_char(next_byte) unless next_byte.nil?
          end
        end

        def read_csi_sequence
          seq = +"["
          loop do
            byte = read_byte_with_timeout(ESCAPE_TIMEOUT)
            break if byte.nil?

            seq << byte
            # CSI sequences end with a letter or ~
            break if byte.match?(/[A-Za-z~]/)
          end

          if (key = ESCAPE_SEQUENCES[seq])
            @queue << { type: :key, key: }
          end
          # Unknown sequences are silently dropped
        end

        def emit_char(byte)
          return if byte.nil?
          return if byte.ord < 32

          @queue << { type: :char, char: byte }
        end

        def read_byte_with_timeout(timeout)
          return nil unless @io.wait_readable(timeout)

          @io.read_nonblock(1)
        rescue IO::WaitReadable
          nil
        rescue IOError
          # Covers EOFError (subclass of IOError)
          @running = false
          nil
        end
      end
    end
  end
end
