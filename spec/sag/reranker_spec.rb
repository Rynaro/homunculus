# frozen_string_literal: true

require "semantic_logger"
SemanticLogger.default_level = :fatal

require_relative "../../lib/homunculus/memory/embedder"
require_relative "../../lib/homunculus/sag/reranker"

RSpec.describe Homunculus::SAG::Reranker do
  let(:snippet_a) do
    Homunculus::SAG::Snippet.from_search(url: "https://example.com/a", title: "Title", body: "Body", rank: 1)
  end
  let(:snippet_b) do
    Homunculus::SAG::Snippet.from_search(url: "https://example.com/b", title: "Other", body: "Content", rank: 2)
  end
  let(:snippet_c) do
    Homunculus::SAG::Snippet.from_search(url: "https://example.com/c", title: "Third", body: "More", rank: 3)
  end

  describe "#rerank" do
    context "when snippets list is empty" do
      subject(:reranker) { described_class.new }

      it "returns an empty array" do
        result = reranker.rerank(query: "ruby programming", snippets: [])

        expect(result).to eq([])
      end
    end

    context "when no embedder is provided" do
      subject(:reranker) { described_class.new }

      it "assigns score 1.0 to the first snippet via positional fallback" do
        result = reranker.rerank(query: "ruby programming", snippets: [snippet_a, snippet_b, snippet_c])

        expect(result.first.score).to eq(1.0)
      end

      it "returns snippets sorted by descending positional score" do
        result = reranker.rerank(query: "ruby programming", snippets: [snippet_a, snippet_b, snippet_c])

        scores = result.map(&:score)
        expect(scores).to eq(scores.sort.reverse)
      end

      it "assigns lower score to later-positioned snippets" do
        result = reranker.rerank(query: "ruby programming", snippets: [snippet_a, snippet_b])

        top_score = result.max_by(&:score).score
        bottom_score = result.min_by(&:score).score
        expect(top_score).to be > bottom_score
      end
    end

    context "when an embedder is provided" do
      subject(:reranker) { described_class.new(embedder: embedder) }

      let(:embedder) { instance_double(Homunculus::Memory::Embedder) }

      it "calls embed for the query and each snippet" do
        allow(embedder).to receive(:embed).with("ruby programming").and_return([1.0, 0.0, 0.0])
        allow(embedder).to receive(:embed).with("Title Body").and_return([0.9, 0.1, 0.0])
        allow(embedder).to receive(:embed).with("Other Content").and_return([0.5, 0.5, 0.0])

        reranker.rerank(query: "ruby programming", snippets: [snippet_a, snippet_b])

        expect(embedder).to have_received(:embed).with("ruby programming")
        expect(embedder).to have_received(:embed).with("Title Body")
        expect(embedder).to have_received(:embed).with("Other Content")
      end

      it "uses cosine_similarity to assign scores" do
        allow(embedder).to receive(:embed).with("ruby programming").and_return([1.0, 0.0, 0.0])
        allow(embedder).to receive(:embed).with("Title Body").and_return([0.9, 0.1, 0.0])

        result = reranker.rerank(query: "ruby programming", snippets: [snippet_a])
        expected_score = Homunculus::Memory::Embedder.cosine_similarity([1.0, 0.0, 0.0], [0.9, 0.1, 0.0])

        expect(result.first.score).to be_within(0.001).of(expected_score)
      end

      it "returns snippets sorted by descending cosine score" do
        allow(embedder).to receive(:embed).with("ruby programming").and_return([1.0, 0.0, 0.0])
        allow(embedder).to receive(:embed).with("Title Body").and_return([0.9, 0.1, 0.0])
        allow(embedder).to receive(:embed).with("Other Content").and_return([0.1, 0.9, 0.0])

        result = reranker.rerank(query: "ruby programming", snippets: [snippet_a, snippet_b])

        scores = result.map(&:score)
        expect(scores).to eq(scores.sort.reverse)
      end

      it "falls back to positional scoring when embed returns nil for the query" do
        allow(embedder).to receive(:embed).with("ruby programming").and_return(nil)

        result = reranker.rerank(query: "ruby programming", snippets: [snippet_a, snippet_b])

        expect(result.first.score).to eq(1.0)
        scores = result.map(&:score)
        expect(scores).to eq(scores.sort.reverse)
      end

      it "falls back to positional scoring when embedder raises a StandardError" do
        allow(embedder).to receive(:embed).with("ruby programming").and_raise(StandardError, "connection refused")

        result = reranker.rerank(query: "ruby programming", snippets: [snippet_a, snippet_b])

        expect(result.first.score).to eq(1.0)
        scores = result.map(&:score)
        expect(scores).to eq(scores.sort.reverse)
      end

      it "assigns score 0.0 to snippets whose embedding returns nil" do
        allow(embedder).to receive(:embed).with("ruby programming").and_return([1.0, 0.0, 0.0])
        allow(embedder).to receive(:embed).with("Title Body").and_return(nil)

        result = reranker.rerank(query: "ruby programming", snippets: [snippet_a])

        expect(result.first.score).to eq(0.0)
      end
    end
  end
end
