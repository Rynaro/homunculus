# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/homunculus/interfaces/tui"
require_relative "../../../lib/homunculus/interfaces/tui/command_registry"

RSpec.describe Homunculus::Interfaces::TUI::CommandRegistry do
  subject(:registry) { described_class.new }

  describe "#match" do
    it "returns /help for exact /help" do
      expect(registry.match("/help")).to eq("/help")
    end

    it "returns /help for /help with trailing space" do
      expect(registry.match("/help ")).to eq("/help")
    end

    it "returns nil for bare help (no slash)" do
      expect(registry.match("help")).to be_nil
    end

    it "returns /quit for /quit and /exit and /q" do
      expect(registry.match("/quit")).to eq("/quit")
      expect(registry.match("/exit")).to eq("/exit")
      expect(registry.match("/q")).to eq("/q")
    end

    it "returns nil for unknown slash command" do
      expect(registry.match("/unknown")).to be_nil
      expect(registry.match("/")).to be_nil
    end

    it "returns nil for nil or non-slash input" do
      expect(registry.match(nil)).to be_nil
      expect(registry.match("")).to be_nil
      expect(registry.match("  hello  ")).to be_nil
    end
  end

  describe "#suggestions" do
    it "returns commands starting with partial" do
      expect(registry.suggestions("/he")).to include("/help")
      expect(registry.suggestions("/he")).to eq(["/help"])
    end

    it "returns all slash commands for partial /" do
      all = registry.suggestions("/")
      expect(all).to include("/help", "/status", "/clear", "/confirm", "/deny", "/model", "/quit", "/exit", "/q")
      expect(all).to eq(all.sort)
    end

    it "returns /q and /quit for /q" do
      expect(registry.suggestions("/q")).to contain_exactly("/q", "/quit")
    end

    it "returns empty for non-slash partial" do
      expect(registry.suggestions("help")).to eq([])
      expect(registry.suggestions("")).to eq([])
      expect(registry.suggestions(nil)).to eq([])
    end
  end

  describe "#suggestions_with_descriptions" do
    it "returns command and description hashes for partial" do
      list = registry.suggestions_with_descriptions("/he")
      expect(list).to contain_exactly({ command: "/help", description: "Show available commands" })
    end

    it "returns empty for non-slash partial" do
      expect(registry.suggestions_with_descriptions("help")).to eq([])
      expect(registry.suggestions_with_descriptions(nil)).to eq([])
    end
  end
end
