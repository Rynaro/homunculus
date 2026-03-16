# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/homunculus/interfaces/tui/keyboard_reader"

RSpec.describe Homunculus::Interfaces::TUI::KeyboardReader do
  let(:queue) { Thread::Queue.new }

  # Creates a pair of IO objects (reader, writer) backed by a pipe.
  def pipe_pair
    IO.pipe
  end

  describe "#start / #stop" do
    it "starts and stops cleanly" do
      reader, writer = pipe_pair
      kb = described_class.new(reader, queue)
      kb.start
      expect(kb.running?).to be true
      kb.stop
      expect(kb.running?).to be false
    ensure
      begin
        reader.close
      rescue StandardError
        nil
      end
      begin
        writer.close
      rescue StandardError
        nil
      end
    end
  end

  describe "key event emission" do
    def with_reader
      reader, writer = pipe_pair
      kb = described_class.new(reader, queue)
      kb.start
      yield writer, queue
    ensure
      kb.stop
      begin
        reader.close
      rescue StandardError
        nil
      end
      begin
        writer.close
      rescue StandardError
        nil
      end
    end

    it "emits :enter on \\r" do
      with_reader do |writer, q|
        writer.write("\r")
        writer.flush
        sleep(0.05)
        event = begin
          q.pop(true)
        rescue StandardError
          nil
        end
        expect(event).to eq({ type: :key, key: :enter })
      end
    end

    it "emits :enter on \\n" do
      with_reader do |writer, q|
        writer.write("\n")
        writer.flush
        sleep(0.05)
        event = begin
          q.pop(true)
        rescue StandardError
          nil
        end
        expect(event).to eq({ type: :key, key: :enter })
      end
    end

    it "emits :backspace on \\x7f" do
      with_reader do |writer, q|
        writer.write("\x7f")
        writer.flush
        sleep(0.05)
        event = begin
          q.pop(true)
        rescue StandardError
          nil
        end
        expect(event).to eq({ type: :key, key: :backspace })
      end
    end

    it "emits :ctrl_c on \\x03" do
      with_reader do |writer, q|
        writer.write("\x03")
        writer.flush
        sleep(0.05)
        event = begin
          q.pop(true)
        rescue StandardError
          nil
        end
        expect(event).to eq({ type: :key, key: :ctrl_c })
      end
    end

    it "emits :tab on \\t" do
      with_reader do |writer, q|
        writer.write("\t")
        writer.flush
        sleep(0.05)
        event = begin
          q.pop(true)
        rescue StandardError
          nil
        end
        expect(event).to eq({ type: :key, key: :tab })
      end
    end

    it "emits :char for printable characters" do
      with_reader do |writer, q|
        writer.write("a")
        writer.flush
        sleep(0.05)
        event = begin
          q.pop(true)
        rescue StandardError
          nil
        end
        expect(event).to eq({ type: :char, char: "a" })
      end
    end

    it "emits :arrow_up for ESC [ A" do
      with_reader do |writer, q|
        writer.write("\e[A")
        writer.flush
        sleep(0.1)
        event = begin
          q.pop(true)
        rescue StandardError
          nil
        end
        expect(event).to eq({ type: :key, key: :arrow_up })
      end
    end

    it "emits :arrow_down for ESC [ B" do
      with_reader do |writer, q|
        writer.write("\e[B")
        writer.flush
        sleep(0.1)
        event = begin
          q.pop(true)
        rescue StandardError
          nil
        end
        expect(event).to eq({ type: :key, key: :arrow_down })
      end
    end

    it "emits :arrow_left for ESC [ D" do
      with_reader do |writer, q|
        writer.write("\e[D")
        writer.flush
        sleep(0.1)
        event = begin
          q.pop(true)
        rescue StandardError
          nil
        end
        expect(event).to eq({ type: :key, key: :arrow_left })
      end
    end

    it "emits :arrow_right for ESC [ C" do
      with_reader do |writer, q|
        writer.write("\e[C")
        writer.flush
        sleep(0.1)
        event = begin
          q.pop(true)
        rescue StandardError
          nil
        end
        expect(event).to eq({ type: :key, key: :arrow_right })
      end
    end

    it "emits :page_up for ESC [ 5 ~" do
      with_reader do |writer, q|
        writer.write("\e[5~")
        writer.flush
        sleep(0.1)
        event = begin
          q.pop(true)
        rescue StandardError
          nil
        end
        expect(event).to eq({ type: :key, key: :page_up })
      end
    end

    it "emits :page_down for ESC [ 6 ~" do
      with_reader do |writer, q|
        writer.write("\e[6~")
        writer.flush
        sleep(0.1)
        event = begin
          q.pop(true)
        rescue StandardError
          nil
        end
        expect(event).to eq({ type: :key, key: :page_down })
      end
    end
  end

  describe "ESCAPE_SEQUENCES constant" do
    it "maps CSI sequences to semantic keys" do
      seqs = described_class::ESCAPE_SEQUENCES
      expect(seqs["[A"]).to eq(:arrow_up)
      expect(seqs["[B"]).to eq(:arrow_down)
      expect(seqs["[C"]).to eq(:arrow_right)
      expect(seqs["[D"]).to eq(:arrow_left)
      expect(seqs["[5~"]).to eq(:page_up)
      expect(seqs["[6~"]).to eq(:page_down)
    end
  end
end
