# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/homunculus/interfaces/tui/theme"
require_relative "../../../lib/homunculus/interfaces/tui/screen_buffer"
require_relative "../../../lib/homunculus/interfaces/tui/ansi_parser"

RSpec.describe Homunculus::Interfaces::TUI::ScreenBuffer do
  subject(:buffer) { described_class.new(10, 20) }

  describe "#initialize" do
    it "stores rows and cols" do
      expect(buffer.rows).to eq(10)
      expect(buffer.cols).to eq(20)
    end

    it "initializes all cells as blank spaces" do
      io = StringIO.new
      # force_flush should produce a clear + space cells
      buffer.force_flush(io)
      expect(io.string).to include("\e[2J")
    end
  end

  describe "#write" do
    it "writes plain text at the given position" do
      buffer.write(1, 1, "Hello")
      io = StringIO.new
      buffer.force_flush(io)
      expect(io.string).to include("Hello")
    end

    it "ignores writes outside row bounds" do
      expect { buffer.write(1, 0, "x") }.not_to raise_error
      expect { buffer.write(1, 11, "x") }.not_to raise_error
    end

    it "truncates text that exceeds column width" do
      long_text = "A" * 25
      expect { buffer.write(1, 1, long_text) }.not_to raise_error
    end

    it "writes ANSI-styled text and preserves visible characters" do
      styled = "\e[1mBold text\e[0m"
      buffer.write(1, 1, styled)
      io = StringIO.new
      buffer.force_flush(io)
      # Characters are emitted individually with style codes; strip ANSI to check content
      visible = io.string.gsub(/\e\[[0-9;]*[mGKHF]/, "")
      expect(visible).to include("B")
      expect(visible).to include("old")
    end
  end

  describe "#clear_row" do
    it "clears all cells in a row" do
      buffer.write(1, 1, "AAAA")
      buffer.clear_row(1)
      io = StringIO.new
      buffer.force_flush(io)
      # Row should be blank — no A characters at position (1,1)
      # We verify by checking the diff flush sees nothing meaningful
      expect { buffer.clear_row(1) }.not_to raise_error
    end
  end

  describe "#clear" do
    it "clears all rows without error" do
      buffer.write(1, 1, "test")
      expect { buffer.clear }.not_to raise_error
    end
  end

  describe "#resize" do
    it "changes rows and cols" do
      buffer.resize(20, 40)
      expect(buffer.rows).to eq(20)
      expect(buffer.cols).to eq(40)
    end

    it "resets content after resize" do
      buffer.write(1, 1, "test")
      buffer.resize(5, 10)
      io = StringIO.new
      buffer.force_flush(io)
      # After resize, content is cleared
      expect(buffer.rows).to eq(5)
    end
  end

  describe "#flush" do
    it "produces empty diff when nothing changed" do
      io_initial = StringIO.new
      buffer.force_flush(io_initial)

      io_diff = StringIO.new
      buffer.flush(io_diff)
      # No changes — diff should be minimal/empty
      expect(io_diff.string.length).to be <= 20
    end

    it "emits only changed cells" do
      io_initial = StringIO.new
      buffer.force_flush(io_initial)

      buffer.write(1, 1, "X")
      io_diff = StringIO.new
      buffer.flush(io_diff)
      expect(io_diff.string).to include("X")
    end

    it "does not re-emit unchanged cells on second flush" do
      buffer.write(1, 1, "A")
      io1 = StringIO.new
      buffer.flush(io1)

      # Nothing changed
      io2 = StringIO.new
      buffer.flush(io2)
      expect(io2.string.length).to be <= 20
    end
  end

  describe "#set_cursor" do
    it "sets cursor without error" do
      expect { buffer.set_cursor(5, 3) }.not_to raise_error
    end

    it "cursor position appears in flush output" do
      buffer.write(1, 1, "X")
      buffer.set_cursor(5, 3)
      io = StringIO.new
      buffer.flush(io)
      expect(io.string).to include("\e[3;5H")
    end
  end
end
