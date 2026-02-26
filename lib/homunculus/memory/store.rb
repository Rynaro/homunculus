# frozen_string_literal: true

require "oj"
require "pathname"
require "fileutils"

module Homunculus
  module Memory
    class Store
      include SemanticLogger::Loggable

      SUMMARY_PROMPT = <<~PROMPT
        Review this conversation and extract:
        1. Key decisions made
        2. Important facts learned about the user or their projects
        3. Action items or follow-ups
        4. Any preferences or corrections the user stated

        Format as a concise bullet list. If nothing notable happened, respond with "NO_SUMMARY".
      PROMPT

      def initialize(config:, db:, embedder: nil)
        @config = config
        @db = db
        @workspace = Pathname.new(config.agent.workspace_path)
        @indexer = Indexer.new(db:)
        @embedder = embedder
      end

      attr_reader :indexer, :embedder

      # ── Daily log ─────────────────────────────────────────────────────

      # Append summary to today's daily log (memory/YYYY-MM-DD.md)
      def save_conversation_summary(session_id:, summary:)
        date = Date.today.iso8601
        dir = @workspace / "memory"
        FileUtils.mkdir_p(dir)

        path = dir / "#{date}.md"
        File.open(path, "a") do |f|
          f.puts "\n## Session #{session_id[0..7]} — #{Time.now.strftime("%H:%M")}\n"
          f.puts summary
        end

        @indexer.reindex_file(path)
        logger.info("Saved conversation summary", session_id: session_id[0..7], date:)
      end

      # Append an arbitrary note to today's daily log
      def append_daily_log(content:, heading: nil)
        date = Date.today.iso8601
        dir = @workspace / "memory"
        FileUtils.mkdir_p(dir)

        path = dir / "#{date}.md"
        File.open(path, "a") do |f|
          if heading
            f.puts "\n## #{heading}\n"
          else
            f.puts "\n## Note — #{Time.now.strftime("%H:%M")}\n"
          end
          f.puts content
        end

        @indexer.reindex_file(path)
        logger.info("Appended daily log", date:)
      end

      # ── Long-term memory (MEMORY.md) ──────────────────────────────────

      # Write/update a fact in MEMORY.md under the given key heading
      def save_long_term(key:, content:)
        path = @workspace / "MEMORY.md"

        if path.exist?
          existing = path.read(encoding: "utf-8")
          updated = update_section(existing, key, content)
        else
          updated = "# Memory\n\n## #{key}\n\n#{content}\n"
        end

        FileUtils.mkdir_p(path.dirname)
        File.write(path, updated, encoding: "utf-8")
        @indexer.reindex_file(path)
        logger.info("Saved long-term memory", key:)
      end

      # ── Search ────────────────────────────────────────────────────────

      # Hybrid search: BM25 + optional vector similarity
      def search(query, limit: 5)
        bm25_results = @indexer.bm25_search(query, limit: limit * 2)

        if embeddings_available?
          vector_results = vector_search(query, limit: limit * 2)
          fuse(bm25_results, vector_results, limit:)
        else
          bm25_results.first(limit)
        end
      end

      # Build memory context string for system prompt injection.
      # Allocates 25% of budget to MEMORY.md pinned summary, 75% to search results.
      def context_for_prompt(query, max_tokens: nil)
        max_tokens ||= @config.memory.max_context_tokens
        results = search(query, limit: 10)
        return nil if results.empty?

        memory_md = read_memory_md_summary
        parts = []

        if memory_md
          pinned_budget = (max_tokens * 0.25).floor
          parts << Agent::Context::TokenCounter.truncate_to_tokens(memory_md, pinned_budget)
        end

        results_budget = memory_md ? (max_tokens * 0.75).floor : max_tokens
        results_text = results.map do |r|
          source_label = Pathname.new(r.source).basename.to_s
          "- [#{source_label}] #{r.content.gsub("\n", " ").strip}"
        end.join("\n")

        parts << Agent::Context::TokenCounter.truncate_to_tokens(results_text, results_budget)

        parts.join("\n")
      end

      # ── Index management ──────────────────────────────────────────────

      def rebuild_index!
        @indexer.rebuild!(workspace: @workspace)
      end

      # Optionally compute embeddings for all chunks without them
      def compute_embeddings!
        return unless embeddings_available?

        chunks = @db[:memory_chunks]
                 .left_join(:memory_embeddings, chunk_id: :id)
                 .where(Sequel[:memory_embeddings][:chunk_id] => nil)
                 .select(Sequel[:memory_chunks][:id], Sequel[:memory_chunks][:content])
                 .all

        return if chunks.empty?

        logger.info("Computing embeddings", count: chunks.size)

        # Batch in groups of 32
        chunks.each_slice(32) do |batch|
          texts = batch.map { |c| c[:content] }
          embeddings = @embedder.embed_batch(texts)

          now = Time.now.utc.iso8601

          batch.zip(embeddings).each do |chunk, embedding|
            next if embedding.nil?

            @db[:memory_embeddings].insert_conflict(:replace).insert(
              chunk_id: chunk[:id],
              embedding: Embedder.pack_embedding(embedding),
              model: @embedder.instance_variable_get(:@model),
              created_at: now
            )
          end
        end

        logger.info("Embeddings computed", total: chunks.size)
      end

      # ── Auto-summary ──────────────────────────────────────────────────

      # Generate summary prompt text for a session's conversation
      def self.summary_prompt
        SUMMARY_PROMPT
      end

      # Save a session transcript to data/sessions/{session_id}.jsonl
      def save_transcript(session)
        sessions_dir = Pathname.new("data/sessions")
        FileUtils.mkdir_p(sessions_dir)

        path = sessions_dir / "#{session.id}.jsonl"
        File.open(path, "w") do |f|
          session.messages.each do |msg|
            f.puts Oj.dump(msg.transform_keys(&:to_s), mode: :compat)
          end
        end

        logger.info("Saved transcript", session_id: session.id, messages: session.messages.size)
      end

      # ── Predicates ────────────────────────────────────────────────────

      def embeddings_available?
        return @embeddings_available unless @embeddings_available.nil?

        @embeddings_available = @embedder&.available? || false
      end

      # Clear cached availability check (useful after model pull)
      def reset_embeddings_check!
        @embeddings_available = nil
      end

      private

      # ── Vector search ─────────────────────────────────────────────────

      def vector_search(query, limit: 10)
        query_embedding = @embedder.embed(query)
        return [] if query_embedding.nil?

        # Fetch all chunks that have embeddings
        rows = @db[:memory_chunks]
               .join(:memory_embeddings, chunk_id: :id)
               .select(
                 Sequel[:memory_chunks][:id].as(:chunk_id),
                 Sequel[:memory_chunks][:source],
                 Sequel[:memory_chunks][:content],
                 Sequel[:memory_chunks][:metadata],
                 Sequel[:memory_embeddings][:embedding]
               )
               .all

        # Compute cosine similarity for each
        scored = rows.filter_map do |row|
          embedding = Embedder.unpack_embedding(row[:embedding])
          next unless embedding

          score = Embedder.cosine_similarity(query_embedding, embedding)
          SearchResult.new(
            chunk_id: row[:chunk_id],
            source: row[:source],
            content: row[:content],
            metadata: row[:metadata],
            score:
          )
        end

        scored.sort_by { |r| -r.score }.first(limit)
      end

      # ── Hybrid fusion ────────────────────────────────────────────────

      def fuse(bm25_results, vector_results, limit:, vector_weight: 0.7, text_weight: 0.3)
        scores = Hash.new(0.0)

        bm25_results.each_with_index do |r, i|
          scores[r.chunk_id] += text_weight * (1.0 / (i + 1)) # reciprocal rank
        end

        vector_results.each_with_index do |r, i|
          scores[r.chunk_id] += vector_weight * (1.0 / (i + 1))
        end

        all_results = (bm25_results + vector_results).uniq(&:chunk_id)
        all_results.sort_by { |r| -scores[r.chunk_id] }.first(limit)
      end

      # ── MEMORY.md helpers ─────────────────────────────────────────────

      def update_section(text, key, content)
        heading_pattern = /^## #{Regexp.escape(key)}\s*$/
        lines = text.lines

        # Find the section start
        start_idx = lines.index { |l| l.match?(heading_pattern) }

        if start_idx
          # Find the next heading at same or higher level
          end_idx = lines[(start_idx + 1)..].index { |l| l.match?(/^## /) }
          end_idx = end_idx ? start_idx + 1 + end_idx : lines.length

          # Replace section content
          new_section = ["## #{key}\n", "\n", "#{content}\n", "\n"]
          lines[start_idx...end_idx] = new_section
          lines.join
        else
          # Append new section at end
          text.chomp + "\n\n## #{key}\n\n#{content}\n"
        end
      end

      def read_memory_md_summary
        path = @workspace / "MEMORY.md"
        return nil unless path.exist?

        content = path.read(encoding: "utf-8")
        return nil if content.strip.empty?

        # Return first 2000 chars as summary context
        content.length > 2000 ? content[0...2000] : content
      end
    end
  end
end
