# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/homunculus/interfaces/tui"
require_relative "../../../lib/homunculus/interfaces/tui/input_buffer"

RSpec.describe Homunculus::Interfaces::TUI::InputBuffer do
  subject(:buffer) { described_class.new }

  describe "#to_s and #clear" do
    it "starts empty" do
      expect(buffer.to_s).to eq("")
      expect(buffer.cursor).to eq(0)
    end

    it "clear resets buffer and cursor" do
      buffer.insert("a")
      buffer.insert("b")
      buffer.clear
      expect(buffer.to_s).to eq("")
      expect(buffer.cursor).to eq(0)
    end
  end

  describe "#insert" do
    it "inserts at cursor and advances cursor" do
      buffer.insert("a")
      expect(buffer.to_s).to eq("a")
      expect(buffer.cursor).to eq(1)
      buffer.insert("b")
      expect(buffer.to_s).to eq("ab")
      expect(buffer.cursor).to eq(2)
    end

    it "inserts in the middle when cursor is not at end" do
      buffer.insert("a")
      buffer.insert("b")
      buffer.move_left
      buffer.insert("x")
      expect(buffer.to_s).to eq("axb")
      expect(buffer.cursor).to eq(2)
    end

    it "ignores nil and empty string" do
      buffer.insert("a")
      buffer.insert(nil)
      buffer.insert("")
      expect(buffer.to_s).to eq("a")
    end
  end

  describe "#backspace" do
    it "deletes char before cursor and moves cursor left" do
      buffer.insert("a")
      buffer.insert("b")
      buffer.backspace
      expect(buffer.to_s).to eq("a")
      expect(buffer.cursor).to eq(1)
    end

    it "deletes at cursor position when cursor is in middle" do
      buffer.insert("a")
      buffer.insert("b")
      buffer.insert("c")
      buffer.move_left
      buffer.move_left
      buffer.backspace
      expect(buffer.to_s).to eq("bc")
      expect(buffer.cursor).to eq(0)
    end

    it "does nothing at cursor 0" do
      buffer.backspace
      expect(buffer.to_s).to eq("")
      buffer.insert("a")
      buffer.move_home
      buffer.backspace
      expect(buffer.to_s).to eq("a")
      expect(buffer.cursor).to eq(0)
    end
  end

  describe "#delete" do
    it "deletes char at cursor" do
      buffer.insert("a")
      buffer.insert("b")
      buffer.move_left
      buffer.delete
      expect(buffer.to_s).to eq("a")
      expect(buffer.cursor).to eq(1)
    end

    it "does nothing when cursor at end" do
      buffer.insert("a")
      buffer.delete
      expect(buffer.to_s).to eq("a")
    end

    it "does nothing when empty" do
      buffer.delete
      expect(buffer.to_s).to eq("")
    end
  end

  describe "#move_left and #move_right" do
    it "move_left decrements cursor and clamps at 0" do
      buffer.insert("ab")
      buffer.move_left
      expect(buffer.cursor).to eq(1)
      buffer.move_left
      expect(buffer.cursor).to eq(0)
      buffer.move_left
      expect(buffer.cursor).to eq(0)
    end

    it "move_right increments cursor and clamps at length" do
      buffer.insert("ab")
      buffer.move_right
      expect(buffer.cursor).to eq(2)
      buffer.move_right
      expect(buffer.cursor).to eq(2)
      buffer.move_left
      buffer.move_left
      buffer.move_left
      expect(buffer.cursor).to eq(0)
    end
  end

  describe "#move_home and #move_end" do
    it "move_home sets cursor to 0" do
      buffer.insert("hello")
      buffer.move_home
      expect(buffer.cursor).to eq(0)
    end

    it "move_end sets cursor to buffer length" do
      buffer.insert("hello")
      buffer.move_end
      expect(buffer.cursor).to eq(5)
    end
  end

  describe "#move_word_left and #move_word_right" do
    it "move_word_left jumps to start of current or previous word" do
      buffer.insert("foo bar baz")
      buffer.move_end
      buffer.move_word_left
      expect(buffer.cursor).to eq(8)
      buffer.move_word_left
      expect(buffer.cursor).to eq(4)
      buffer.move_word_left
      expect(buffer.cursor).to eq(0)
      buffer.move_word_left
      expect(buffer.cursor).to eq(0)
    end

    it "move_word_right jumps to end of current word or start of next" do
      buffer.insert("foo bar baz")
      buffer.move_home
      buffer.move_word_right
      expect(buffer.cursor).to eq(3)
      buffer.move_word_right
      expect(buffer.cursor).to eq(7)
      buffer.move_word_right
      expect(buffer.cursor).to eq(11)
      buffer.move_word_right
      expect(buffer.cursor).to eq(11)
    end

    it "move_word_left from middle of word goes to start of word" do
      buffer.insert("foo")
      buffer.move_right
      buffer.move_word_left
      expect(buffer.cursor).to eq(0)
    end

    it "move_word_right at end does nothing" do
      buffer.insert("foo")
      buffer.move_end
      buffer.move_word_right
      expect(buffer.cursor).to eq(3)
    end
  end

  describe "#delete_word_backward" do
    it "deletes word before cursor" do
      buffer.insert("foo bar baz")
      buffer.move_end
      buffer.delete_word_backward
      expect(buffer.to_s).to eq("foo bar ")
      expect(buffer.cursor).to eq(8)
    end

    it "deletes from cursor back to start when no space before" do
      buffer.insert("foo")
      buffer.move_end
      buffer.delete_word_backward
      expect(buffer.to_s).to eq("")
      expect(buffer.cursor).to eq(0)
    end

    it "does nothing when cursor at 0" do
      buffer.insert("foo")
      buffer.move_home
      buffer.delete_word_backward
      expect(buffer.to_s).to eq("foo")
    end
  end

  describe "cursor boundaries" do
    it "cursor always in 0..buf.length after operations" do
      buffer.insert("x")
      expect(buffer.cursor).to be_between(0, buffer.to_s.length)
      buffer.move_right
      buffer.move_right
      expect(buffer.cursor).to eq(1)
      buffer.move_left
      buffer.move_left
      expect(buffer.cursor).to eq(0)
    end
  end
end
