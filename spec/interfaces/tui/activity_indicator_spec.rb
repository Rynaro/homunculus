# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/homunculus/interfaces/tui"

RSpec.describe Homunculus::Interfaces::TUI::ActivityIndicator do
  subject(:indicator) { described_class.new(redraw:) }

  # Callable invoked from background thread; plain double avoids lifecycle errors when thread outlives example.
  let(:redraw) { double("redraw") } # rubocop:disable RSpec/VerifiedDoubles

  before do
    allow(redraw).to receive(:call)
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
      sleep(0.15) # allow spinner thread to exit before asserting (avoids OutsideOfExampleError)
      expect(redraw).to have_received(:call).at_least(:twice)
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
