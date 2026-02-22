# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Tools::Registry do
  subject(:registry) { described_class.new }

  let(:session) { Homunculus::Session.new }

  describe "#register" do
    it "registers a tool instance" do
      tool = Homunculus::Tools::Echo.new
      registry.register(tool)

      expect(registry.tool_names).to include("echo")
    end

    it "rejects non-Base instances" do
      expect { registry.register("not a tool") }.to raise_error(ArgumentError, /Tools::Base/)
    end
  end

  describe "#execute" do
    before do
      registry.register(Homunculus::Tools::Echo.new)
    end

    it "dispatches to the correct tool" do
      result = registry.execute(name: "echo", arguments: { text: "hello" }, session:)

      expect(result.success).to be true
      expect(result.output).to eq("hello")
    end

    it "raises UnknownToolError for unregistered tools" do
      expect do
        registry.execute(name: "nonexistent", arguments: {}, session:)
      end.to raise_error(Homunculus::Tools::UnknownToolError, /nonexistent/)
    end

    it "normalizes string arguments to symbols" do
      result = registry.execute(name: "echo", arguments: { "text" => "hello" }, session:)

      expect(result.success).to be true
      expect(result.output).to eq("hello")
    end

    it "handles JSON string arguments" do
      result = registry.execute(name: "echo", arguments: '{"text": "hello"}', session:)

      expect(result.success).to be true
      expect(result.output).to eq("hello")
    end
  end

  describe "#definitions" do
    before do
      registry.register(Homunculus::Tools::Echo.new)
      registry.register(Homunculus::Tools::DatetimeNow.new)
    end

    it "returns definitions for all registered tools" do
      defs = registry.definitions

      expect(defs.size).to eq(2)
      expect(defs.map { |d| d[:name] }).to contain_exactly("echo", "datetime_now")
    end

    it "includes JSON schema parameters" do
      defs = registry.definitions
      echo_def = defs.find { |d| d[:name] == "echo" }

      expect(echo_def[:parameters][:type]).to eq("object")
      expect(echo_def[:parameters][:properties]).to have_key("text")
    end
  end

  describe "#definitions_for_prompt" do
    before do
      registry.register(Homunculus::Tools::Echo.new)
    end

    it "returns human-readable tool descriptions" do
      prompt = registry.definitions_for_prompt

      expect(prompt).to include("echo")
      expect(prompt).to include("Returns the input text")
    end
  end

  describe "#requires_confirmation?" do
    before do
      registry.register(Homunculus::Tools::Echo.new)
      registry.register(Homunculus::Tools::WorkspaceWrite.new)
    end

    it "returns false for safe tools" do
      expect(registry.requires_confirmation?("echo")).to be false
    end

    it "returns true for elevated tools" do
      expect(registry.requires_confirmation?("workspace_write")).to be true
    end

    it "returns false for unknown tools" do
      expect(registry.requires_confirmation?("nonexistent")).to be false
    end
  end
end
