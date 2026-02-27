# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "sequel"

RSpec.describe Homunculus::Tools::MemoryCurate do
  subject(:tool) { described_class.new(memory_store:) }

  let(:tmpdir) { Dir.mktmpdir("memory_curate_test") }
  let(:workspace_dir) { File.join(tmpdir, "workspace") }
  let(:db) { Sequel.sqlite }
  let(:config) do
    raw = {
      "gateway" => { "host" => "127.0.0.1" },
      "models" => {},
      "agent" => { "workspace_path" => workspace_dir },
      "tools" => { "sandbox" => {} },
      "memory" => { "db_path" => File.join(tmpdir, "memory.db"), "max_context_tokens" => 4096 },
      "security" => {}
    }
    Homunculus::Config.new(raw)
  end
  let(:memory_store) { Homunculus::Memory::Store.new(config:, db:) }
  let(:session) { Homunculus::Session.new }

  before do
    FileUtils.mkdir_p(workspace_dir)
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe "metadata" do
    it "has correct tool name" do
      expect(tool.name).to eq("memory_curate")
    end

    it "requires confirmation" do
      expect(tool.requires_confirmation).to be true
    end

    it "has :mixed trust level" do
      expect(tool.trust_level).to eq(:mixed)
    end
  end

  describe "#execute — replace mode (default)" do
    it "creates MEMORY.md and writes a section" do
      result = tool.execute(
        arguments: { section: "Preferences", content: "User prefers dark mode." },
        session:
      )

      expect(result.success).to be true
      expect(result.output).to include("MEMORY.md updated")
      expect(result.output).to include("Preferences")

      content = File.read(File.join(workspace_dir, "MEMORY.md"))
      expect(content).to include("## Preferences")
      expect(content).to include("User prefers dark mode.")
    end

    it "replaces an existing section, removing old content" do
      memory_store.save_long_term(key: "Preferences", content: "Old content.")

      result = tool.execute(
        arguments: { section: "Preferences", content: "New content.", mode: "replace" },
        session:
      )

      expect(result.success).to be true

      content = File.read(File.join(workspace_dir, "MEMORY.md"))
      expect(content).not_to include("Old content.")
      expect(content).to include("New content.")
      expect(content.scan("## Preferences").size).to eq(1)
    end

    it "uses replace as the default mode" do
      memory_store.save_long_term(key: "Stack", content: "Original stack.")

      tool.execute(
        arguments: { section: "Stack", content: "Updated stack." },
        session:
      )

      content = File.read(File.join(workspace_dir, "MEMORY.md"))
      expect(content).not_to include("Original stack.")
      expect(content).to include("Updated stack.")
    end
  end

  describe "#execute — append mode" do
    it "appends to an existing section" do
      memory_store.save_long_term(key: "Projects", content: "- Project A")

      result = tool.execute(
        arguments: { section: "Projects", content: "- Project B", mode: "append" },
        session:
      )

      expect(result.success).to be true

      content = File.read(File.join(workspace_dir, "MEMORY.md"))
      expect(content).to include("Project A")
      expect(content).to include("Project B")
    end

    it "creates section if it does not exist in append mode" do
      result = tool.execute(
        arguments: { section: "New Section", content: "- First entry", mode: "append" },
        session:
      )

      expect(result.success).to be true

      content = File.read(File.join(workspace_dir, "MEMORY.md"))
      expect(content).to include("## New Section")
      expect(content).to include("First entry")
    end
  end

  describe "#execute — validation failures" do
    it "fails when section is missing" do
      result = tool.execute(
        arguments: { content: "some content" },
        session:
      )

      expect(result.success).to be false
      expect(result.error).to include("Missing required parameter: section")
    end

    it "fails when content is missing" do
      result = tool.execute(
        arguments: { section: "Preferences" },
        session:
      )

      expect(result.success).to be false
      expect(result.error).to include("Missing required parameter: content")
    end

    it "fails when section is blank" do
      result = tool.execute(
        arguments: { section: "   ", content: "some content" },
        session:
      )

      expect(result.success).to be false
      expect(result.error).to include("Missing required parameter: section")
    end
  end
end
