# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Homunculus::Agent::PromptBuilder do
  subject(:builder) do
    described_class.new(workspace_path: workspace_dir, tool_registry:)
  end

  let(:workspace_dir) { Dir.mktmpdir("homunculus-prompt-spec-") }
  let(:tool_registry) { Homunculus::Tools::Registry.new }

  before do
    tool_registry.register(Homunculus::Tools::Echo.new)
    tool_registry.register(Homunculus::Tools::DatetimeNow.new)

    File.write(File.join(workspace_dir, "SOUL.md"), <<~MD)
      # Soul

      You are Homunculus, a personal AI agent.
    MD

    File.write(File.join(workspace_dir, "AGENTS.md"), <<~MD)
      # Operating Instructions

      Follow the APIVR-Delta methodology.
    MD

    File.write(File.join(workspace_dir, "USER.md"), <<~MD)
      # User Profile

      Name: Rynaro
    MD
  end

  after { FileUtils.rm_rf(workspace_dir) }

  describe "#build" do
    it "includes soul section from SOUL.md" do
      prompt = builder.build

      expect(prompt).to include("<soul>")
      expect(prompt).to include("</soul>")
      expect(prompt).to include("Homunculus")
    end

    it "omits identity section (identity is merged into SOUL.md)" do
      prompt = builder.build

      expect(prompt).not_to include("<identity>")
    end

    it "includes operating instructions from AGENTS.md" do
      prompt = builder.build

      expect(prompt).to include("<operating_instructions>")
      expect(prompt).to include("</operating_instructions>")
    end

    it "includes user context from USER.md" do
      prompt = builder.build

      expect(prompt).to include("<user_context>")
      expect(prompt).to include("</user_context>")
      expect(prompt).to include("Rynaro")
    end

    it "includes available tools section" do
      prompt = builder.build

      expect(prompt).to include("<available_tools>")
      expect(prompt).to include("echo")
      expect(prompt).to include("datetime_now")
    end

    it "includes system info section" do
      prompt = builder.build

      expect(prompt).to include("<system_info>")
      expect(prompt).to include("Current time:")
      expect(prompt).to include("Ruby #{RUBY_VERSION}")
    end

    it "omits memory context when no memory store configured" do
      prompt = builder.build

      expect(prompt).not_to include("<memory_context>")
    end

    it "includes memory context when memory store provides context" do
      mock_memory = instance_double(Homunculus::Memory::Store)
      allow(mock_memory).to receive(:context_for_prompt).and_return("- [MEMORY.md] User prefers Ruby")

      session = Homunculus::Session.new
      session.add_message(role: :user, content: "What do I prefer?")

      builder_with_mem = described_class.new(
        workspace_path: workspace_dir, tool_registry:, memory: mock_memory
      )
      prompt = builder_with_mem.build(session:)

      expect(prompt).to include("<memory_context>")
      expect(prompt).to include("User prefers Ruby")
    end

    it "uses XML-style delimiters" do
      prompt = builder.build

      %w[soul operating_instructions user_context available_tools system_info].each do |section|
        expect(prompt).to include("<#{section}>")
        expect(prompt).to include("</#{section}>")
      end
    end

    it "omits sections for missing files" do
      builder_empty = described_class.new(
        workspace_path: "/nonexistent/path",
        tool_registry:
      )

      prompt = builder_empty.build

      expect(prompt).not_to include("<soul>")
      expect(prompt).not_to include("<user_context>")
      expect(prompt).to include("<available_tools>")
      expect(prompt).to include("<system_info>")
    end
  end
end
