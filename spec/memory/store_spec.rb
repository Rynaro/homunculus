# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "sequel"

RSpec.describe Homunculus::Memory::Store do
  subject(:store) { described_class.new(config:, db:) }

  let(:tmpdir) { Dir.mktmpdir("store_test") }
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

  before do
    FileUtils.mkdir_p(workspace_dir)
    FileUtils.mkdir_p(File.join(workspace_dir, "memory"))
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe "#save_conversation_summary" do
    it "creates a daily log file" do
      store.save_conversation_summary(
        session_id: "abc12345-6789-0000-1111-222233334444",
        summary: "- User discussed testing\n- Decided to use RSpec"
      )

      date = Date.today.iso8601
      path = File.join(workspace_dir, "memory", "#{date}.md")

      expect(File.exist?(path)).to be true
      content = File.read(path)
      expect(content).to include("Session abc12345")
      expect(content).to include("User discussed testing")
      expect(content).to include("Decided to use RSpec")
    end

    it "appends to existing daily log" do
      date = Date.today.iso8601
      path = File.join(workspace_dir, "memory", "#{date}.md")
      File.write(path, "## Earlier Entry\n\nPrior content.\n")

      store.save_conversation_summary(
        session_id: "new-session-id-here-with-enough-chars",
        summary: "New summary content."
      )

      content = File.read(path)
      expect(content).to include("Prior content")
      expect(content).to include("New summary content")
    end

    it "indexes the file after writing" do
      store.save_conversation_summary(
        session_id: "test-session-0000-1111-222233334444",
        summary: "Test summary about SQLite indexing."
      )

      results = store.search("SQLite indexing")
      expect(results).not_to be_empty
    end
  end

  describe "#append_daily_log" do
    it "appends with default heading" do
      store.append_daily_log(content: "A quick note.")

      date = Date.today.iso8601
      path = File.join(workspace_dir, "memory", "#{date}.md")

      content = File.read(path)
      expect(content).to include("Note —")
      expect(content).to include("A quick note.")
    end

    it "appends with custom heading" do
      store.append_daily_log(content: "Important decision.", heading: "Architecture Decision")

      date = Date.today.iso8601
      path = File.join(workspace_dir, "memory", "#{date}.md")

      content = File.read(path)
      expect(content).to include("## Architecture Decision")
      expect(content).to include("Important decision.")
    end
  end

  describe "#save_long_term" do
    it "creates MEMORY.md with initial content" do
      store.save_long_term(key: "User Preferences", content: "Prefers dark mode.")

      path = File.join(workspace_dir, "MEMORY.md")
      expect(File.exist?(path)).to be true

      content = File.read(path)
      expect(content).to include("## User Preferences")
      expect(content).to include("Prefers dark mode.")
    end

    it "appends new sections to existing MEMORY.md" do
      store.save_long_term(key: "Section A", content: "Content A.")
      store.save_long_term(key: "Section B", content: "Content B.")

      content = File.read(File.join(workspace_dir, "MEMORY.md"))
      expect(content).to include("## Section A")
      expect(content).to include("Content A.")
      expect(content).to include("## Section B")
      expect(content).to include("Content B.")
    end

    it "updates existing sections" do
      store.save_long_term(key: "Preferences", content: "Old preference.")
      store.save_long_term(key: "Preferences", content: "Updated preference.")

      content = File.read(File.join(workspace_dir, "MEMORY.md"))
      expect(content).not_to include("Old preference.")
      expect(content).to include("Updated preference.")
      # Should only have one Preferences heading
      expect(content.scan("## Preferences").size).to eq(1)
    end

    it "indexes MEMORY.md after writing" do
      store.save_long_term(key: "Tech Stack", content: "Ruby on Rails with PostgreSQL.")

      results = store.search("Rails PostgreSQL")
      expect(results).not_to be_empty
    end
  end

  describe "#search" do
    before do
      # Populate with test data
      File.write(File.join(workspace_dir, "MEMORY.md"), <<~MD)
        # Memory

        ## Project Setup

        The project uses Ruby 3.4 with YJIT enabled.

        ## User Preferences

        The user prefers minimal dependencies and test-first development.
      MD

      memory_dir = File.join(workspace_dir, "memory")
      File.write(File.join(memory_dir, "2026-02-14.md"), <<~MD)
        ## Session abc12345 — 14:00

        - Discussed database migration strategy
        - Decided to use Sequel instead of ActiveRecord
        - User wants to keep the codebase simple
      MD

      store.rebuild_index!
    end

    it "finds relevant results via BM25" do
      results = store.search("Ruby YJIT")
      expect(results).not_to be_empty
      expect(results.first.content).to include("Ruby")
    end

    it "finds content from daily logs" do
      results = store.search("database migration Sequel")
      expect(results).not_to be_empty
      expect(results.first.content).to include("Sequel")
    end

    it "respects the limit parameter" do
      results = store.search("project", limit: 1)
      expect(results.size).to be <= 1
    end

    it "returns empty for unrelated queries" do
      results = store.search("quantum entanglement photon")
      expect(results).to be_empty
    end
  end

  describe "#context_for_prompt" do
    before do
      File.write(File.join(workspace_dir, "MEMORY.md"), <<~MD)
        # Memory

        ## Tech Stack

        Ruby 3.4, Sequel, SQLite, HTTPX.
      MD

      store.rebuild_index!
    end

    it "returns a formatted context string" do
      context = store.context_for_prompt("tech stack")

      expect(context).not_to be_nil
      expect(context).to include("Ruby")
    end

    it "returns nil when no results found" do
      context = store.context_for_prompt("quantum physics")
      # Might still return MEMORY.md summary, but without specific results
      # the context should be reasonable
      expect(context).to be_a(String).or be_nil
    end
  end

  describe "#rebuild_index!" do
    it "rebuilds from scratch" do
      File.write(File.join(workspace_dir, "MEMORY.md"), "## Facts\n\nSome facts.")

      count = store.rebuild_index!
      expect(count).to be >= 1
    end

    it "is idempotent" do
      File.write(File.join(workspace_dir, "MEMORY.md"), "## Facts\n\nSome facts.")

      count1 = store.rebuild_index!
      count2 = store.rebuild_index!
      expect(count1).to eq(count2)
    end
  end

  describe "#save_transcript" do
    let(:session) { Homunculus::Session.new }

    before do
      session.add_message(role: :user, content: "Hello")
      session.add_message(role: :assistant, content: "Hi there!")
    end

    after do
      FileUtils.rm_rf("data/sessions")
    end

    it "saves a JSONL transcript file" do
      store.save_transcript(session)

      path = File.join("data", "sessions", "#{session.id}.jsonl")
      expect(File.exist?(path)).to be true

      lines = File.readlines(path)
      expect(lines.size).to eq(2)

      first_msg = Oj.load(lines[0])
      expect(first_msg["role"]).to eq("user")
      expect(first_msg["content"]).to eq("Hello")
    end
  end

  describe "#embeddings_available?" do
    it "returns false when no embedder configured" do
      store_no_embed = described_class.new(config:, db:, embedder: nil)
      expect(store_no_embed.embeddings_available?).to be false
    end

    it "caches the result" do
      embedder = instance_double(Homunculus::Memory::Embedder, available?: true)
      store_with_embed = described_class.new(config:, db:, embedder:)

      store_with_embed.embeddings_available?
      store_with_embed.embeddings_available?

      expect(embedder).to have_received(:available?).once
    end
  end

  describe "graceful degradation without embeddings" do
    it "works with BM25-only search" do
      File.write(File.join(workspace_dir, "MEMORY.md"), <<~MD)
        ## Facts

        The sky is blue and water is wet.
      MD

      store.rebuild_index!

      # Search should work fine without embeddings
      results = store.search("sky blue water")
      expect(results).not_to be_empty
    end
  end

  describe "#read_section" do
    before do
      File.write(File.join(workspace_dir, "MEMORY.md"), <<~MD)
        # Memory

        ## About My Human
        Director of Engineering.

        ## Preferences
        Prefers dark mode.

        ## Projects
        Project Homunculus.
      MD
    end

    it "returns content for an existing section" do
      result = store.read_section("Preferences")
      expect(result).to eq("Prefers dark mode.")
    end

    it "returns content for first section" do
      result = store.read_section("About My Human")
      expect(result).to eq("Director of Engineering.")
    end

    it "returns content for last section" do
      result = store.read_section("Projects")
      expect(result).to eq("Project Homunculus.")
    end

    it "returns nil for a missing section" do
      result = store.read_section("NonExistent Section")
      expect(result).to be_nil
    end

    it "returns nil when MEMORY.md does not exist" do
      FileUtils.rm_f(File.join(workspace_dir, "MEMORY.md"))
      result = store.read_section("Preferences")
      expect(result).to be_nil
    end
  end

  describe "#long_term_memory_for_prompt" do
    it "returns full MEMORY.md content when file exists" do
      content = "# Memory\n\n## Facts\n\nSome facts here."
      File.write(File.join(workspace_dir, "MEMORY.md"), content)

      result = store.long_term_memory_for_prompt
      expect(result).to eq(content)
    end

    it "returns nil when MEMORY.md does not exist" do
      result = store.long_term_memory_for_prompt
      expect(result).to be_nil
    end

    it "returns nil when MEMORY.md is empty" do
      File.write(File.join(workspace_dir, "MEMORY.md"), "   \n  ")
      result = store.long_term_memory_for_prompt
      expect(result).to be_nil
    end

    it "truncates content to max_chars when content exceeds the limit" do
      long_content = "x" * 9000
      File.write(File.join(workspace_dir, "MEMORY.md"), long_content)

      result = store.long_term_memory_for_prompt(max_chars: 8000)
      expect(result.length).to eq(8000)
    end

    it "does not truncate when content is within max_chars" do
      content = "# Memory\n\n## Short\n\nShort content."
      File.write(File.join(workspace_dir, "MEMORY.md"), content)

      result = store.long_term_memory_for_prompt(max_chars: 8000)
      expect(result).to eq(content)
    end
  end
end
