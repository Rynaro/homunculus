# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/homunculus/interfaces/tui"

RSpec.describe Homunculus::Interfaces::TUI::MessageRenderer do
  subject(:renderer) { described_class.new(width:, agent_name:) }

  let(:width) { 80 }
  let(:agent_name) { "Homunculus" }

  describe "#render" do
    it "renders a user message with You prefix" do
      msg = { role: :user, text: "Hello world", timestamp: nil }
      lines = renderer.render(msg)
      joined = lines.join
      expect(joined).to include("You")
      expect(joined).to include("Hello world")
    end

    it "renders an assistant message with agent name prefix" do
      msg = { role: :assistant, text: "I can help", timestamp: nil }
      lines = renderer.render(msg)
      joined = lines.join
      expect(joined).to include(agent_name)
      expect(joined).to include("I can help")
    end

    it "wraps long lines at width" do
      long = "word " * 30
      msg = { role: :user, text: long.strip, timestamp: nil }
      lines = renderer.render(msg)
      raw = lines.map { |l| l.gsub(/\e\[[0-9;]*[mGKHF]/, "") }
      raw.each { |line| expect(line.length).to be <= width + 2 }
    end

    it "includes timestamp when present" do
      t = Time.now
      msg = { role: :user, text: "hi", timestamp: t }
      lines = renderer.render(msg)
      expect(lines.join).to include(t.strftime("[%H:%M]"))
    end

    it "renders bold in assistant messages" do
      msg = { role: :assistant, text: "This is **important** text", timestamp: nil }
      lines = renderer.render(msg)
      expect(lines.join).to include("\e[1m")
      expect(lines.join).to include("important")
    end

    it "renders inline code in assistant messages" do
      msg = { role: :assistant, text: "Run `ls -la` to list", timestamp: nil }
      lines = renderer.render(msg)
      expect(lines.join).to include("ls -la")
    end

    it "does not apply markdown to user messages" do
      msg = { role: :user, text: "Use **bold** here", timestamp: nil }
      lines = renderer.render(msg)
      joined = lines.join
      # Literal **bold** must appear (not converted to ANSI bold)
      expect(joined).to include("**bold**")
    end

    it "renders empty assistant message as label only" do
      msg = { role: :assistant, text: "", timestamp: nil }
      lines = renderer.render(msg)
      expect(lines.size).to eq(1)
      expect(lines.first).to include(agent_name)
    end

    it "wraps long unbroken tokens instead of overflowing" do
      token = "x" * 120
      msg = { role: :assistant, text: token, timestamp: nil }
      lines = renderer.render(msg)

      expect(lines.length).to be > 1
      lines.each do |line|
        expect(Homunculus::Interfaces::TUI::Theme.visible_len(line)).to be <= width
      end
    end

    it "preserves repeated spaces and explicit blank lines in plain text" do
      msg = { role: :user, text: "alpha  beta\n\ngamma", timestamp: nil }
      lines = renderer.render(msg)
      raw = lines.map { |line| line.gsub(/\e\[[0-9;]*[mGKHF]/, "") }

      expect(raw.join("\n")).to include("alpha  beta")
      expect(raw.count { |line| line.strip.empty? }).to be >= 1
      raw.each { |line| expect(line.length).to be <= width }
    end

    it "wraps code block lines to the available width" do
      code = "```ruby\n#{"x" * 120}\n```"
      msg = { role: :assistant, text: code, timestamp: nil }
      lines = renderer.render(msg)

      expect(lines.length).to be > 1
      lines.each do |line|
        expect(Homunculus::Interfaces::TUI::Theme.visible_len(line)).to be <= width
      end
    end

    it "wraps tool request cards instead of truncating long arguments" do
      msg = {
        role: :tool_request,
        tool_name: "workspace_write",
        arguments: { path: "/tmp/#{"segment" * 20}.txt" },
        timestamp: nil
      }
      lines = renderer.render(msg)
      raw = lines.map { |line| line.gsub(/\e\[[0-9;]*[mGKHF]/, "") }

      expect(raw.join("\n")).to include("workspace_write")
      lines.each do |line|
        expect(Homunculus::Interfaces::TUI::Theme.visible_len(line)).to be <= width
      end
    end
  end
end
