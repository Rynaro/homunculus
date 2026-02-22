# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "sequel"

RSpec.describe Homunculus::Memory::Indexer do
  subject(:indexer) { described_class.new(db:) }

  let(:db) { Sequel.sqlite }

  describe "#ensure_schema!" do
    before { indexer } # force subject instantiation to run ensure_schema!

    it "creates memory_chunks table" do
      expect(db.tables).to include(:memory_chunks)
    end

    it "creates memory_embeddings table" do
      expect(db.tables).to include(:memory_embeddings)
    end

    it "creates memory_fts virtual table" do
      # Sequel's #tables may not list FTS5 virtual tables; verify via raw SQL
      result = db.fetch("SELECT name FROM sqlite_master WHERE type='table' AND name='memory_fts'").all
      expect(result).not_to be_empty
    end

    it "is idempotent" do
      expect { described_class.new(db:) }.not_to raise_error
    end
  end

  describe "#chunk_markdown" do
    it "handles empty text" do
      expect(indexer.chunk_markdown("")).to eq([])
      expect(indexer.chunk_markdown(nil)).to eq([])
      expect(indexer.chunk_markdown("   ")).to eq([])
    end

    it "returns a single chunk for small text" do
      text = "Hello, this is a small note."
      chunks = indexer.chunk_markdown(text)

      expect(chunks.size).to eq(1)
      expect(chunks.first).to eq(text)
    end

    it "splits by headings" do
      text = <<~MD
        ## First Section

        Content of first section.

        ## Second Section

        Content of second section.
      MD

      chunks = indexer.chunk_markdown(text)

      expect(chunks.size).to eq(2)
      expect(chunks[0]).to include("First Section")
      expect(chunks[0]).to include("Content of first section")
      expect(chunks[1]).to include("Second Section")
      expect(chunks[1]).to include("Content of second section")
    end

    it "splits by triple headings" do
      text = <<~MD
        ### Subsection A

        Content A.

        ### Subsection B

        Content B.
      MD

      chunks = indexer.chunk_markdown(text)

      expect(chunks.size).to eq(2)
    end

    it "splits large sections by paragraphs" do
      # Create a large section that exceeds MAX_CHUNK_TOKENS
      paragraphs = 20.times.map { |i| "Paragraph #{i}: #{"word " * 100}" }
      text = paragraphs.join("\n\n")

      chunks = indexer.chunk_markdown(text)

      expect(chunks.size).to be > 1
      chunks.each do |chunk|
        # Each chunk should be within reasonable bounds
        estimated_tokens = (chunk.length.to_f / 4).ceil
        expect(estimated_tokens).to be <= 600 # allow some slack for overlap
      end
    end

    it "handles text with no headings or paragraphs" do
      text = "A single long line of text. " * 50
      chunks = indexer.chunk_markdown(text)

      expect(chunks).not_to be_empty
      expect(chunks.all? { |c| !c.empty? }).to be true
    end
  end

  describe "#index_file" do
    let(:tmpdir) { Dir.mktmpdir("indexer_test") }

    after { FileUtils.rm_rf(tmpdir) }

    it "indexes a markdown file into chunks" do
      path = File.join(tmpdir, "test.md")
      File.write(path, <<~MD)
        ## Topic A

        Some content about topic A.

        ## Topic B

        Some content about topic B.
      MD

      indexer.index_file(path)

      expect(db[:memory_chunks].count).to eq(2)
      expect(db[:memory_chunks].first[:source]).to eq(path)
    end

    it "skips unchanged content on re-index" do
      path = File.join(tmpdir, "stable.md")
      File.write(path, "## Stable\n\nThis won't change.")

      indexer.index_file(path)
      first_update = db[:memory_chunks].first[:updated_at]

      sleep 0.01
      indexer.index_file(path)

      expect(db[:memory_chunks].first[:updated_at]).to eq(first_update)
    end

    it "updates chunks when content changes" do
      path = File.join(tmpdir, "changing.md")
      File.write(path, "## Version 1\n\nOriginal content.")

      indexer.index_file(path)
      expect(db[:memory_chunks].first[:content]).to include("Original content")

      File.write(path, "## Version 1\n\nUpdated content.")
      indexer.index_file(path)
      expect(db[:memory_chunks].first[:content]).to include("Updated content")
    end

    it "removes stale chunks when file shrinks" do
      path = File.join(tmpdir, "shrink.md")
      File.write(path, "## A\n\nContent A.\n\n## B\n\nContent B.\n\n## C\n\nContent C.")

      indexer.index_file(path)
      expect(db[:memory_chunks].count).to eq(3)

      File.write(path, "## A\n\nContent A only.")
      indexer.index_file(path)
      expect(db[:memory_chunks].count).to eq(1)
    end

    it "stores content hashes for dedup" do
      path = File.join(tmpdir, "hashed.md")
      File.write(path, "## Test\n\nSome content.")

      indexer.index_file(path)

      chunk = db[:memory_chunks].first
      expect(chunk[:content_hash]).to match(/\A[a-f0-9]{64}\z/)
    end

    it "indexes daily log files with correct metadata" do
      path = File.join(tmpdir, "2026-02-14.md")
      File.write(path, "## Session abc12345\n\nToday we discussed testing.")

      indexer.index_file(path)

      chunk = db[:memory_chunks].first
      metadata = Oj.load(chunk[:metadata])
      expect(metadata["date"]).to eq("2026-02-14")
      expect(metadata["type"]).to eq("daily_log")
    end

    it "skips nonexistent files" do
      indexer.index_file("/nonexistent/path.md")
      expect(db[:memory_chunks].count).to eq(0)
    end
  end

  describe "#index_directory" do
    let(:tmpdir) { Dir.mktmpdir("indexer_dir_test") }

    after { FileUtils.rm_rf(tmpdir) }

    it "indexes all markdown files recursively" do
      File.write(File.join(tmpdir, "a.md"), "## File A\n\nContent A.")
      FileUtils.mkdir_p(File.join(tmpdir, "sub"))
      File.write(File.join(tmpdir, "sub", "b.md"), "## File B\n\nContent B.")

      indexer.index_directory(tmpdir)

      expect(db[:memory_chunks].count).to eq(2)
    end

    it "ignores non-markdown files" do
      File.write(File.join(tmpdir, "a.md"), "## Markdown\n\nContent.")
      File.write(File.join(tmpdir, "b.txt"), "Plain text.")

      indexer.index_directory(tmpdir)

      expect(db[:memory_chunks].count).to eq(1)
    end
  end

  describe "#rebuild!" do
    let(:tmpdir) { Dir.mktmpdir("indexer_rebuild_test") }

    after { FileUtils.rm_rf(tmpdir) }

    it "clears and rebuilds the entire index" do
      memory_dir = File.join(tmpdir, "memory")
      FileUtils.mkdir_p(memory_dir)
      File.write(File.join(memory_dir, "2026-02-14.md"), "## Session\n\nFirst indexing.")

      indexer.rebuild!(workspace: tmpdir)
      expect(db[:memory_chunks].count).to eq(1)

      # Modify content
      File.write(File.join(memory_dir, "2026-02-14.md"), "## Session\n\nSecond indexing.")

      count = indexer.rebuild!(workspace: tmpdir)
      expect(count).to eq(1)
      expect(db[:memory_chunks].first[:content]).to include("Second indexing")
    end

    it "includes MEMORY.md if present" do
      File.write(File.join(tmpdir, "MEMORY.md"), "## Preferences\n\nUser likes Ruby.")

      count = indexer.rebuild!(workspace: tmpdir)
      expect(count).to eq(1)
    end

    it "produces consistent results from same input" do
      memory_dir = File.join(tmpdir, "memory")
      FileUtils.mkdir_p(memory_dir)
      File.write(File.join(memory_dir, "note.md"), "## A\n\nContent A.\n\n## B\n\nContent B.")
      File.write(File.join(tmpdir, "MEMORY.md"), "## Facts\n\nSome facts.")

      count1 = indexer.rebuild!(workspace: tmpdir)
      chunks1 = db[:memory_chunks].all.map { |c| c[:content_hash] }.sort

      count2 = indexer.rebuild!(workspace: tmpdir)
      chunks2 = db[:memory_chunks].all.map { |c| c[:content_hash] }.sort

      expect(count1).to eq(count2)
      expect(chunks1).to eq(chunks2)
    end
  end

  describe "#bm25_search" do
    let(:tmpdir) { Dir.mktmpdir("indexer_search_test") }

    after { FileUtils.rm_rf(tmpdir) }

    before do
      File.write(File.join(tmpdir, "ruby.md"), <<~MD)
        ## Ruby Programming

        Ruby is a dynamic programming language focused on simplicity and productivity.
        It has an elegant syntax that is natural to read and easy to write.
      MD

      File.write(File.join(tmpdir, "python.md"), <<~MD)
        ## Python Programming

        Python is a high-level programming language known for its readability.
        It uses indentation to define code blocks.
      MD

      File.write(File.join(tmpdir, "cooking.md"), <<~MD)
        ## Pasta Recipe

        Boil water, add pasta, cook for 8 minutes. Drain and serve with sauce.
      MD

      indexer.index_directory(tmpdir)
    end

    it "finds relevant content with keyword search" do
      results = indexer.bm25_search("ruby programming")

      expect(results).not_to be_empty
      expect(results.first.content).to include("Ruby")
    end

    it "returns SearchResult objects" do
      results = indexer.bm25_search("programming")

      expect(results.first).to be_a(Homunculus::Memory::SearchResult)
      expect(results.first.chunk_id).not_to be_nil
      expect(results.first.source).not_to be_nil
      expect(results.first.content).not_to be_nil
      expect(results.first.score).to be_a(Numeric)
    end

    it "respects the limit parameter" do
      results = indexer.bm25_search("programming", limit: 1)
      expect(results.size).to eq(1)
    end

    it "returns empty array for no matches" do
      results = indexer.bm25_search("quantum physics")
      expect(results).to be_empty
    end

    it "handles special characters in query" do
      results = indexer.bm25_search("what's the ruby (programming) language?")
      expect(results).to be_an(Array)
    end
  end

  describe "#reindex_file" do
    let(:tmpdir) { Dir.mktmpdir("reindex_test") }

    after { FileUtils.rm_rf(tmpdir) }

    it "removes old chunks and re-indexes" do
      path = File.join(tmpdir, "test.md")
      File.write(path, "## Old\n\nOld content.")
      indexer.index_file(path)

      expect(db[:memory_chunks].count).to eq(1)
      expect(db[:memory_chunks].first[:content]).to include("Old content")

      File.write(path, "## New\n\nBrand new content.\n\n## Extra\n\nMore new stuff.")
      indexer.reindex_file(path)

      expect(db[:memory_chunks].count).to eq(2)
      contents = db[:memory_chunks].select_map(:content)
      expect(contents.join).to include("Brand new content")
    end

    it "cleans up when file is deleted" do
      path = File.join(tmpdir, "temp.md")
      File.write(path, "## Temp\n\nTemporary.")
      indexer.index_file(path)

      expect(db[:memory_chunks].count).to eq(1)

      File.delete(path)
      indexer.reindex_file(path)

      expect(db[:memory_chunks].count).to eq(0)
    end
  end
end
