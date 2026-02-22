# frozen_string_literal: true

require "httpx"

module Homunculus
  module Memory
    class Embedder
      include SemanticLogger::Loggable

      DEFAULT_MODEL = "nomic-embed-text"

      def initialize(base_url:, model: DEFAULT_MODEL)
        @base_url = base_url.chomp("/")
        @model = model
      end

      # Returns a float array (embedding vector) or nil on failure
      def embed(text)
        response = HTTPX
                   .with(timeout: { operation_timeout: 30 })
                   .post("#{@base_url}/api/embed", json: {
                           model: @model,
                           input: text
                         })

        unless response.respond_to?(:status)
          msg = response.respond_to?(:error) && response.error ? response.error.message : "unknown"
          logger.warn("Embedding request failed (connection error)", error: msg)
          return nil
        end

        unless response.status == 200
          logger.warn("Embedding request failed", status: response.status)
          return nil
        end

        data = Oj.load(response.body.to_s)
        data["embeddings"]&.first
      rescue StandardError => e
        logger.warn("Embedding failed, falling back to BM25-only", error: e.message)
        nil
      end

      # Batch embed multiple texts — returns array of float arrays
      def embed_batch(texts)
        return [] if texts.empty?

        response = HTTPX
                   .with(timeout: { operation_timeout: 120 })
                   .post("#{@base_url}/api/embed", json: {
                           model: @model,
                           input: texts
                         })

        unless response.respond_to?(:status)
          msg = response.respond_to?(:error) && response.error ? response.error.message : "unknown"
          logger.warn("Batch embedding failed (connection error)", error: msg, count: texts.size)
          return Array.new(texts.size)
        end

        unless response.status == 200
          logger.warn("Batch embedding failed", status: response.status, count: texts.size)
          return Array.new(texts.size)
        end

        data = Oj.load(response.body.to_s)
        data["embeddings"] || Array.new(texts.size)
      rescue StandardError => e
        logger.warn("Batch embedding failed", error: e.message)
        Array.new(texts.size)
      end

      # Check if the embedding model is available in Ollama
      def available?
        response = HTTPX
                   .with(timeout: { operation_timeout: 5 })
                   .get("#{@base_url}/api/tags")

        return false unless response.respond_to?(:status)
        return false unless response.status == 200

        models = Oj.load(response.body.to_s)["models"]
        models&.any? { |m| m["name"]&.start_with?(@model) } || false
      rescue StandardError
        false
      end

      # ── Vector math ─────────────────────────────────────────────────

      def self.cosine_similarity(a, b)
        return 0.0 if a.nil? || b.nil? || a.empty? || b.empty?
        return 0.0 if a.length != b.length

        dot = 0.0
        mag_a = 0.0
        mag_b = 0.0

        a.length.times do |i|
          dot   += a[i] * b[i]
          mag_a += a[i] * a[i]
          mag_b += b[i] * b[i]
        end

        mag_a = Math.sqrt(mag_a)
        mag_b = Math.sqrt(mag_b)
        return 0.0 if mag_a.zero? || mag_b.zero?

        dot / (mag_a * mag_b)
      end

      # Pack a float array into a binary blob (for SQLite storage)
      def self.pack_embedding(embedding)
        embedding.pack("f*")
      end

      # Unpack a binary blob back into a float array
      def self.unpack_embedding(blob)
        return nil if blob.nil?

        blob.unpack("f*")
      end
    end
  end
end
