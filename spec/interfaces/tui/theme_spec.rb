# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/homunculus/interfaces/tui/theme"

RSpec.describe Homunculus::Interfaces::TUI::Theme do
  describe ".use_256_colors?" do
    it "returns true when TERM includes 256" do
      allow(ENV).to receive(:[]).with("TERM").and_return("xterm-256color")
      allow(ENV).to receive(:[]).with("COLORTERM").and_return(nil)
      expect(described_class.use_256_colors?).to be true
    end

    it "returns false when TERM is basic" do
      allow(ENV).to receive(:[]).with("TERM").and_return("xterm")
      allow(ENV).to receive(:[]).with("COLORTERM").and_return(nil)
      expect(described_class.use_256_colors?).to be false
    end
  end

  describe ".palette" do
    it "returns a hash with semantic color keys" do
      palette = described_class.palette
      expect(palette).to include(:user, :assistant, :info, :error, :muted, :accent)
      expect(palette[:user]).to start_with("\e[")
      expect(palette[:assistant]).to start_with("\e[")
    end
  end

  describe ".paint" do
    it "wraps text with ANSI codes and reset" do
      result = described_class.paint("hello", :bold)
      expect(result).to include("\e[1m")
      expect(result).to include("hello")
      expect(result).to include("\e[0m")
    end

    it "applies multiple styles" do
      result = described_class.paint("x", :bold, :user)
      expect(result).to include("\e[1m")
      expect(result).to include("x")
    end

    it "handles unknown style by ignoring it" do
      result = described_class.paint("hi", :unknown_style)
      expect(result).to include("hi")
      expect(result).to include("\e[0m")
    end

    it "maps semantic names :user_label and :dim" do
      expect(described_class.paint("a", :user_label)).to include("a")
      expect(described_class.paint("b", :muted)).to include("b")
    end
  end

  describe ".visible_len" do
    it "strips ANSI and returns character count" do
      colored = described_class.paint("hello", :cyan)
      expect(described_class.visible_len(colored)).to eq(5)
    end

    it "returns 0 for empty string" do
      expect(described_class.visible_len("")).to eq(0)
    end
  end

  describe "constants" do
    it "defines separator and header chars" do
      expect(described_class::SEPARATOR_CHAR).to be_a(String)
      expect(described_class::HEADER_TOP_CHAR).to be_a(String)
      expect(described_class::HEADER_BOTTOM_CHAR).to be_a(String)
      expect(described_class::PROMPT_CHAR).to be_a(String)
      expect(described_class::BULLET_CHAR).to be_a(String)
    end

    it "defines role indicator chars" do
      expect(described_class::ROLE_USER).to be_a(String)
      expect(described_class::ROLE_ASSISTANT).to be_a(String)
      expect(described_class::ROLE_INFO).to be_a(String)
      expect(described_class::ROLE_ERROR).to be_a(String)
    end
  end

  describe "instance methods (for TUI include)" do
    let(:tui_class) do
      Class.new do
        include Homunculus::Interfaces::TUI::Theme
      end
    end

    it "paint delegates to Theme.paint" do
      obj = tui_class.new
      result = obj.paint("test", :bold)
      expect(result).to include("test")
      expect(result).to include("\e[0m")
    end

    it "visible_len delegates to Theme.visible_len" do
      obj = tui_class.new
      expect(obj.visible_len("hello")).to eq(5)
      colored = described_class.paint("hello", :user)
      expect(obj.visible_len(colored)).to eq(5)
    end
  end
end
