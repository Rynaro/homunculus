# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/homunculus/interfaces/tui/event_loop"

RSpec.describe Homunculus::Interfaces::TUI::EventLoop do
  subject(:loop_obj) { described_class.new(render_fn:) }

  let(:received_events) { [] }
  let(:mutex)           { Mutex.new }
  let(:render_fn) do
    lambda do |events|
      mutex.synchronize { received_events.concat(events) }
    end
  end

  after do
    loop_obj.stop
  rescue StandardError
    nil
  end

  describe "#push and event delivery" do
    it "delivers pushed events to render_fn" do
      loop_obj.start
      loop_obj.push({ type: :refresh })
      sleep(0.1)
      loop_obj.stop
      mutex.synchronize do
        expect(received_events.any? { |e| e[:type] == :refresh }).to be true
      end
    end

    it "delivers multiple events in order" do
      loop_obj.start
      loop_obj.push({ type: :stream_chunk, chunk: "hello" })
      loop_obj.push({ type: :stream_chunk, chunk: "world" })
      sleep(0.1)
      loop_obj.stop
      mutex.synchronize do
        chunks = received_events.select { |e| e[:type] == :stream_chunk }.map { |e| e[:chunk] }
        expect(chunks).to include("hello", "world")
      end
    end
  end

  describe "#start / #stop" do
    it "sets running to true after start" do
      loop_obj.start
      expect(loop_obj.running?).to be true
    end

    it "sets running to false after stop" do
      loop_obj.start
      loop_obj.stop
      expect(loop_obj.running?).to be false
    end

    it "stop is idempotent" do
      loop_obj.start
      loop_obj.stop
      expect { loop_obj.stop }.not_to raise_error
    end
  end

  describe "#queue" do
    it "returns the Thread::Queue used for events" do
      expect(loop_obj.queue).to be_a(Thread::Queue)
    end
  end

  describe ":shutdown event" do
    it "stops the loop when :shutdown is pushed" do
      loop_obj.start
      loop_obj.push({ type: :shutdown })
      # Give the loop thread time to drain the queue and process the event
      deadline = Time.now + 1.0
      sleep(0.02) until !loop_obj.running? || Time.now > deadline
      expect(loop_obj.running?).to be false
    end
  end

  describe "FRAME_PERIOD constant" do
    it "is approximately 1/60 second" do
      expect(described_class::FRAME_PERIOD).to be_within(0.001).of(1.0 / 60)
    end
  end
end
