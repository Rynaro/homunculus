# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "sequel"

RSpec.describe "Memory tools" do
  let(:tmpdir) { Dir.mktmpdir("memory_tools_test") }
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
    FileUtils.mkdir_p(File.join(workspace_dir, "memory"))
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe Homunculus::Tools::MemorySearch do
    subject(:tool) { described_class.new(memory_store:) }

    it "has correct metadata" do
      expect(tool.name).to eq("memory_search")
      expect(tool.requires_confirmation).to be false
      expect(tool.trust_level).to eq(:trusted)
    end

    it "searches memory and returns results" do
      File.write(File.join(workspace_dir, "MEMORY.md"), "## Facts\n\nRuby is a great language.")
      memory_store.rebuild_index!

      result = tool.execute(arguments: { query: "Ruby language" }, session:)

      expect(result.success).to be true
      expect(result.output).to include("Ruby")
    end

    it "returns a message when no results found" do
      result = tool.execute(arguments: { query: "nonexistent topic xyzzy" }, session:)

      expect(result.success).to be true
      expect(result.output).to include("No relevant memories found")
    end

    it "fails when query is missing" do
      result = tool.execute(arguments: {}, session:)

      expect(result.success).to be false
      expect(result.error).to include("Missing required parameter")
    end

    it "fails when query is empty" do
      result = tool.execute(arguments: { query: "  " }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Missing required parameter")
    end

    it "respects the limit parameter" do
      # Create multiple chunks
      File.write(File.join(workspace_dir, "MEMORY.md"), <<~MD)
        ## A

        Ruby programming content.

        ## B

        More Ruby content here.

        ## C

        Even more Ruby stuff.
      MD
      memory_store.rebuild_index!

      result = tool.execute(arguments: { query: "Ruby", limit: 1 }, session:)
      expect(result.success).to be true
    end
  end

  describe Homunculus::Tools::MemorySave do
    subject(:tool) { described_class.new(memory_store:) }

    it "has correct metadata" do
      expect(tool.name).to eq("memory_save")
      expect(tool.requires_confirmation).to be false
      expect(tool.trust_level).to eq(:trusted)
    end

    it "saves a fact to MEMORY.md" do
      result = tool.execute(
        arguments: { key: "Preferences", content: "User likes dark mode." },
        session:
      )

      expect(result.success).to be true
      expect(result.output).to include("Saved to MEMORY.md")
      expect(result.output).to include("Preferences")

      content = File.read(File.join(workspace_dir, "MEMORY.md"))
      expect(content).to include("User likes dark mode.")
    end

    it "fails when key is missing" do
      result = tool.execute(arguments: { content: "some content" }, session:)
      expect(result.success).to be false
      expect(result.error).to include("Missing required parameter: key")
    end

    it "fails when content is missing" do
      result = tool.execute(arguments: { key: "test" }, session:)
      expect(result.success).to be false
      expect(result.error).to include("Missing required parameter: content")
    end
  end

  describe Homunculus::Tools::MemoryDailyLog do
    subject(:tool) { described_class.new(memory_store:) }

    it "has correct metadata" do
      expect(tool.name).to eq("memory_daily_log")
      expect(tool.requires_confirmation).to be false
      expect(tool.trust_level).to eq(:trusted)
    end

    it "appends to today's daily log" do
      result = tool.execute(
        arguments: { content: "Discussed project architecture." },
        session:
      )

      expect(result.success).to be true
      expect(result.output).to include(Date.today.iso8601)

      date = Date.today.iso8601
      path = File.join(workspace_dir, "memory", "#{date}.md")
      content = File.read(path)
      expect(content).to include("Discussed project architecture.")
    end

    it "supports custom heading" do
      result = tool.execute(
        arguments: { content: "Chose SQLite.", heading: "Decision Log" },
        session:
      )

      expect(result.success).to be true

      date = Date.today.iso8601
      path = File.join(workspace_dir, "memory", "#{date}.md")
      content = File.read(path)
      expect(content).to include("## Decision Log")
      expect(content).to include("Chose SQLite.")
    end

    it "fails when content is missing" do
      result = tool.execute(arguments: {}, session:)
      expect(result.success).to be false
      expect(result.error).to include("Missing required parameter: content")
    end
  end
end
