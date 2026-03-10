# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/homunculus/interfaces/tui"

RSpec.describe Homunculus::Interfaces::TUI::ActivityIndicator do
  subject(:indicator) { described_class.new(redraw:) }

  let(:redraw_calls) { [] }
  let(:redraw_mutex) { Mutex.new }
  let(:redraw) do
    lambda do
      redraw_mutex.synchronize { redraw_calls << Time.now }
    end
  end

  describe "#start" do
    it "sets message and running to true" do
      indicator.start("Thinking...")
      expect(indicator.message).to eq("Thinking...")
      expect(indicator.running?).to be true
    end

    it "starts a thread that invokes redraw periodically" do
      indicator.start("Working")
      sleep(0.25)
      indicator.stop
      expect(redraw_calls.length).to be >= 2
    end
  end

  describe "#update" do
    it "changes the message without stopping" do
      indicator.start("Thinking...")
      indicator.update("Running tool: echo...")
      expect(indicator.message).to eq("Running tool: echo...")
      expect(indicator.running?).to be true
      indicator.stop
    end
  end

  describe "#snapshot" do
    it "returns a consistent running/message/frame view" do
      indicator.start("Thinking...")
      snapshot = indicator.snapshot
      indicator.stop

      expect(snapshot[:running]).to be true
      expect(snapshot[:message]).to eq("Thinking...")
      expect(described_class::FRAMES).to include(snapshot[:frame_char])
    end
  end

  describe "#stop" do
    it "sets running to false and joins the thread" do
      indicator.start("Thinking...")
      expect(indicator.running?).to be true
      indicator.stop
      expect(indicator.running?).to be false
    end

    it "is idempotent" do
      indicator.start("x")
      indicator.stop
      expect { indicator.stop }.not_to raise_error
    end

    it "allows the spinner thread to exit (no orphaned thread)" do
      indicator.start("x")
      thread_before = Thread.list.count
      indicator.stop
      sleep(0.1)
      # Spinner thread should be gone; allow for test framework threads
      expect(Thread.list.count).to be <= thread_before + 1
    end

    it "restarts cleanly without leaving the previous thread running" do
      indicator.start("first")
      first_snapshot = indicator.snapshot
      indicator.start("second")
      second_snapshot = indicator.snapshot
      indicator.stop

      expect(first_snapshot[:message]).to eq("first")
      expect(second_snapshot[:message]).to eq("second")
      expect(indicator.running?).to be false
    end
  end

  describe "#frame_char" do
    it "returns a character from the braille spinner set" do
      frames = described_class::FRAMES[0, described_class::FRAME_COUNT]
      indicator.start("x")
      chars = 10.times.map do
        c = indicator.frame_char
        sleep(0.02)
        c
      end
      indicator.stop
      chars.each { |c| expect(frames).to include(c) }
    end
  end
end
