# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/homunculus/interfaces/tui/layout"

RSpec.describe Homunculus::Interfaces::TUI::Layout do
  subject(:layout) { described_class.new(term_width: 80, term_height: 24) }

  describe "#initialize" do
    it "stores term_width and term_height" do
      expect(layout.term_width).to eq(80)
      expect(layout.term_height).to eq(24)
    end
  end

  describe "#chrome_rows" do
    it "returns sum of header + status + separator + input rows" do
      expected = described_class::HEADER_ROWS +
                 described_class::STATUS_ROWS +
                 described_class::SEPARATOR_ROWS +
                 described_class::INPUT_ROWS
      expect(layout.chrome_rows).to eq(expected)
    end
  end

  describe "#chat_rows" do
    it "returns positive value for a 24-row terminal" do
      expect(layout.chat_rows).to be_positive
    end

    it "is at least MIN_CHAT_ROWS" do
      tiny_layout = described_class.new(term_width: 80, term_height: 10)
      expect(tiny_layout.chat_rows).to be >= described_class::MIN_CHAT_ROWS
    end

    it "suggestions overlay rather than reducing chat space" do
      # chat_rows = max(term_height - chrome_rows, MIN_CHAT_ROWS) — no SUGGESTION_ROWS deduction
      available = layout.term_height - layout.chrome_rows
      expected  = [available, described_class::MIN_CHAT_ROWS].max
      expect(layout.chat_rows).to eq(expected)
    end
  end

  describe "#chat_width" do
    it "is term_width minus 2 for wide terminals" do
      expect(layout.chat_width).to eq(78)
    end

    it "is at least 10 for very narrow terminals" do
      narrow = described_class.new(term_width: 5, term_height: 24)
      expect(narrow.chat_width).to eq(10)
    end
  end

  describe "row boundaries" do
    it "header_rows starts at row 1" do
      expect(layout.header_rows.first).to eq(1)
    end

    it "chat starts after header" do
      expect(layout.chat_start_row).to eq(described_class::HEADER_ROWS + 1)
    end

    it "status_row is after chat region" do
      expect(layout.status_row).to eq(layout.chat_end_row + 1)
    end

    it "separator_row is after status_row" do
      expect(layout.separator_row).to eq(layout.status_row + 1)
    end

    it "input_row is the last row" do
      expect(layout.input_row).to eq(layout.term_height)
    end

    it "suggestion_start_row is after separator_row" do
      # Suggestions overlay the chat area — they start just after the separator.
      # On a 24-row terminal with the new layout, suggestion_start_row equals input_row
      # because suggestions share the same row band as the input area.
      expect(layout.suggestion_start_row).to be > layout.separator_row
    end

    it "chat_region covers chat_start_row..chat_end_row" do
      expect(layout.chat_region).to eq(layout.chat_start_row..layout.chat_end_row)
    end
  end

  describe "#resize" do
    it "updates dimensions" do
      layout.resize(term_width: 120, term_height: 40)
      expect(layout.term_width).to eq(120)
      expect(layout.term_height).to eq(40)
    end

    it "recalculates chat_rows after resize" do
      old_chat_rows = layout.chat_rows
      layout.resize(term_width: 80, term_height: 50)
      expect(layout.chat_rows).to be > old_chat_rows
    end
  end
end
