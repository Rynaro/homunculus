# frozen_string_literal: true

require "digest"
require "oj"
require "pathname"
require "sequel"

module Homunculus
  module Memory
    class Indexer
      include SemanticLogger::Loggable

      MAX_CHUNK_TOKENS = 512
      OVERLAP_TOKENS   = 64

      # Approximate token count: ~4 chars per token for English text
      CHARS_PER_TOKEN = 4

      def initialize(db:)
        @db = db
        ensure_schema!
      end

      # ── Schema ────────────────────────────────────────────────────────

      def ensure_schema!
        @db.create_table?(:memory_chunks) do
          String :id, primary_key: true
          String :source, null: false
          Text   :content, null: false
          String :content_hash, null: false
          Text   :metadata
          String :created_at, null: false
          String :updated_at, null: false

          index :source
          index :content_hash
        end

        @db.create_table?(:memory_embeddings) do
          String :chunk_id, primary_key: true
          File   :embedding
          String :model, null: false
          String :created_at, null: false

          foreign_key [:chunk_id], :memory_chunks, key: :id
        end

        # FTS5 virtual table — Sequel doesn't support CREATE VIRTUAL TABLE natively
        return if @db.tables.include?(:memory_fts)

        @db.run <<~SQL
          CREATE VIRTUAL TABLE memory_fts USING fts5(
            source,
            chunk_id,
            content,
            metadata,
            tokenize='porter unicode61'
          )
        SQL
      end

      # ── Indexing ──────────────────────────────────────────────────────

      # Index a single markdown file into chunks
      def index_file(path)
        path = Pathname.new(path)
        return unless path.exist? && path.file?

        content = path.read(encoding: "utf-8")
        source = path.to_s
        chunks = chunk_markdown(content)

        logger.debug("Indexing file", source:, chunks: chunks.size)

        chunks.each_with_index do |chunk_text, idx|
          chunk_id = "#{source}##{idx}"
          content_hash = Digest::SHA256.hexdigest(chunk_text)

          # Skip if content hasn't changed
          existing = @db[:memory_chunks].where(id: chunk_id).first
          next if existing && existing[:content_hash] == content_hash

          now = Time.now.utc.iso8601

          metadata = Oj.dump({
                               date: extract_date(path),
                               type: infer_type(path),
                               chunk_index: idx,
                               total_chunks: chunks.size
                             }, mode: :compat)

          if existing
            # Update existing chunk
            @db[:memory_chunks].where(id: chunk_id).update(
              content: chunk_text,
              content_hash:,
              metadata:,
              updated_at: now
            )
            # Update FTS
            @db[:memory_fts].where(chunk_id:).delete
          else
            @db[:memory_chunks].insert(
              id: chunk_id,
              source:,
              content: chunk_text,
              content_hash:,
              metadata:,
              created_at: now,
              updated_at: now
            )
          end

          # Insert into FTS index
          @db[:memory_fts].insert(
            source:,
            chunk_id:,
            content: chunk_text,
            metadata:
          )
        end

        # Remove stale chunks (e.g., file was shortened)
        remove_stale_chunks(source, chunks.size)
      end

      # Index all markdown files in a directory (recursive)
      def index_directory(dir)
        dir = Pathname.new(dir)
        return unless dir.exist? && dir.directory?

        dir.glob("**/*.md").sort.each { |path| index_file(path) }
      end

      # Wipe and rebuild all index data
      def rebuild!(workspace:)
        workspace = Pathname.new(workspace)

        @db.transaction do
          @db[:memory_embeddings].delete
          @db.run("DELETE FROM memory_fts")
          @db[:memory_chunks].delete

          memory_dir = workspace / "memory"
          index_directory(memory_dir) if memory_dir.exist?

          memory_md = workspace / "MEMORY.md"
          index_file(memory_md) if memory_md.exist?
        end

        count = @db[:memory_chunks].count
        logger.info("Index rebuilt", chunks: count)
        count
      end

      # Re-index a single file (called after writes)
      def reindex_file(path)
        path = Pathname.new(path)
        source = path.to_s

        @db.transaction do
          # Remove old data for this source
          chunk_ids = @db[:memory_chunks].where(source:).select_map(:id)
          unless chunk_ids.empty?
            @db[:memory_embeddings].where(chunk_id: chunk_ids).delete
            @db[:memory_fts].where(chunk_id: chunk_ids).delete
            @db[:memory_chunks].where(source:).delete
          end

          # Re-index
          index_file(path) if path.exist?
        end
      end

      # ── BM25 Search ──────────────────────────────────────────────────

      def bm25_search(query, limit: 10)
        # Escape FTS5 special characters
        safe_query = sanitize_fts_query(query)
        return [] if safe_query.empty?

        rows = @db.fetch(<<~SQL, safe_query, limit).all
          SELECT
            memory_fts.chunk_id,
            memory_fts.source,
            memory_fts.content,
            memory_fts.metadata,
            rank
          FROM memory_fts
          WHERE memory_fts MATCH ?
          ORDER BY rank
          LIMIT ?
        SQL

        rows.map do |row|
          SearchResult.new(
            chunk_id: row[:chunk_id],
            source: row[:source],
            content: row[:content],
            metadata: row[:metadata],
            score: -row[:rank] # FTS5 rank is negative (lower = better)
          )
        end
      end

      # ── Chunk access ─────────────────────────────────────────────────

      def chunk_ids_for_source(source)
        @db[:memory_chunks].where(source:).select_map(:id)
      end

      def get_chunk(chunk_id)
        @db[:memory_chunks].where(id: chunk_id).first
      end

      # ── Chunking logic ───────────────────────────────────────────────

      def chunk_markdown(text)
        return [] if text.nil? || text.strip.empty?

        # Split by headings first
        sections = split_by_headings(text)

        chunks = []
        sections.each do |section|
          if estimate_tokens(section) <= MAX_CHUNK_TOKENS
            chunks << section.strip unless section.strip.empty?
          else
            # Split large sections by paragraph breaks
            paragraphs = section.split(/\n\n+/)
            current_chunk = +""

            paragraphs.each do |para|
              para = para.strip
              next if para.empty?

              if estimate_tokens("#{current_chunk}\n\n#{para}") <= MAX_CHUNK_TOKENS
                current_chunk << "\n\n" unless current_chunk.empty?
                current_chunk << para
              elsif current_chunk.empty?
                # Save current chunk and start new one with overlap
                chunks.concat(force_split(para))
                current_chunk = +""
              # Single paragraph exceeds max — force-split by sentences
              else
                chunks << current_chunk.strip
                # Create overlap from end of current chunk
                overlap = extract_overlap(current_chunk)
                current_chunk = overlap.empty? ? +para : "#{overlap}\n\n#{para}"
              end
            end

            chunks << current_chunk.strip unless current_chunk.strip.empty?
          end
        end

        chunks.reject(&:empty?)
      end

      private

      def split_by_headings(text)
        # Split on ## or ### headings, keeping the heading with its section
        parts = text.split(/(?=^\#{2,3}\s)/m)
        return [text] if parts.size <= 1

        parts.reject { |p| p.strip.empty? }
      end

      def estimate_tokens(text)
        (text.length.to_f / CHARS_PER_TOKEN).ceil
      end

      def extract_overlap(text)
        # Take the last OVERLAP_TOKENS worth of text
        max_chars = OVERLAP_TOKENS * CHARS_PER_TOKEN
        return text if text.length <= max_chars

        # Try to break at a sentence boundary
        tail = text[-max_chars..]
        sentence_break = tail.index(/[.!?]\s/)
        if sentence_break
          tail[(sentence_break + 2)..]
        else
          tail
        end
      end

      def force_split(text)
        max_chars = MAX_CHUNK_TOKENS * CHARS_PER_TOKEN
        chunks = []
        pos = 0

        while pos < text.length
          end_pos = [pos + max_chars, text.length].min
          # Try to break at word boundary
          if end_pos < text.length
            space = text.rindex(/\s/, end_pos)
            end_pos = space if space && space > pos
          end
          chunks << text[pos...end_pos].strip
          pos = end_pos
        end

        chunks.reject(&:empty?)
      end

      def sanitize_fts_query(query)
        # Remove FTS5 special operators and wrap terms in quotes for safety
        terms = query.gsub(/[^\w\s]/, " ").split.reject(&:empty?)
        return "" if terms.empty?

        # Use OR to match any term — more forgiving than AND
        terms.map { |t| %("#{t}") }.join(" OR ")
      end

      def remove_stale_chunks(source, current_count)
        stale_ids = @db[:memory_chunks]
                    .where(source:)
                    .where(Sequel.like(:id, "#{source}#%"))
                    .select_map(:id)
                    .select do |id|
                      idx = id.split("#").last.to_i
                      idx >= current_count
        end

        return if stale_ids.empty?

        @db[:memory_embeddings].where(chunk_id: stale_ids).delete
        @db[:memory_fts].where(chunk_id: stale_ids).delete
        @db[:memory_chunks].where(id: stale_ids).delete
      end

      def extract_date(path)
        basename = path.basename(".md").to_s
        return basename if basename.match?(/\A\d{4}-\d{2}-\d{2}\z/)

        nil
      end

      def infer_type(path)
        basename = path.basename(".md").to_s
        return "daily_log" if basename.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        return "long_term" if basename.casecmp("MEMORY").zero?

        "document"
      end
    end

    # Value object for search results
    SearchResult = Data.define(:chunk_id, :source, :content, :metadata, :score)
  end
end
