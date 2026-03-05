# frozen_string_literal: true

require_relative "../../lib/homunculus/sag/snippet"
require_relative "../../lib/homunculus/sag/query_analyzer"
require_relative "../../lib/homunculus/sag/post_processor"
require_relative "../../lib/homunculus/sag/grounded_generator"
require_relative "../../lib/homunculus/sag/retriever"
require_relative "../../lib/homunculus/sag/reranker"
require_relative "../../lib/homunculus/sag/pipeline"

RSpec.describe Homunculus::SAG::Pipeline do
  subject(:pipeline) do
    described_class.new(
      analyzer: analyzer,
      retriever: retriever,
      reranker: reranker,
      generator: generator,
      processor: processor
    )
  end

  let(:snippet_a) do
    Homunculus::SAG::Snippet.from_search(url: "https://a.com", title: "A", body: "Body A", rank: 1)
  end
  let(:snippet_b) do
    Homunculus::SAG::Snippet.from_search(url: "https://b.com", title: "B", body: "Body B", rank: 2)
  end

  let(:analysis) do
    Homunculus::SAG::QueryAnalysis.new(intent: :research, sub_queries: ["test query"], original: "test query")
  end
  let(:generation_result) do
    Homunculus::SAG::GenerationResult.new(
      query: "test query", response: "Answer from [1] and [2].", snippets_used: 2, prompt_chars: 500, error: nil
    )
  end
  let(:processed_result) do
    Homunculus::SAG::ProcessedResult.new(
      text: "Answer from [1] and [2].",
      cited_snippets: [snippet_a.with_score(0.9), snippet_b.with_score(0.7)],
      orphaned_citations: [],
      confidence: 0.8,
      citation_count: 2
    )
  end

  let(:analyzer) { instance_double(Homunculus::SAG::QueryAnalyzer) }
  let(:retriever) { instance_double(Homunculus::SAG::Retriever) }
  let(:reranker) { instance_double(Homunculus::SAG::Reranker) }
  let(:generator) { instance_double(Homunculus::SAG::GroundedGenerator) }
  let(:processor) { instance_double(Homunculus::SAG::PostProcessor) }

  before do
    allow(analyzer).to receive(:analyze).and_return(analysis)
    allow(retriever).to receive(:retrieve).and_return([snippet_a, snippet_b])
    allow(reranker).to receive(:rerank).and_return([snippet_a.with_score(0.9), snippet_b.with_score(0.7)])
    allow(generator).to receive(:generate).and_return(generation_result)
    allow(processor).to receive(:process).and_return(processed_result)
  end

  describe "#run" do
    it "returns a successful PipelineResult" do
      result = pipeline.run("test query")

      expect(result).to be_success
      expect(result.query).to eq("test query")
      expect(result.response).to eq("Answer from [1] and [2].")
      expect(result.confidence).to eq(0.8)
      expect(result.error).to be_nil
    end

    it "includes cited URLs from processed result" do
      result = pipeline.run("test query")

      expect(result.cited_urls).to contain_exactly("https://a.com", "https://b.com")
    end

    it "passes through all pipeline stages in order" do
      pipeline.run("test query")

      expect(analyzer).to have_received(:analyze).with("test query")
      expect(retriever).to have_received(:retrieve).with(query: "test query")
      expect(reranker).to have_received(:rerank)
      expect(generator).to have_received(:generate)
      expect(processor).to have_received(:process)
    end

    it "returns error when no search results found" do
      allow(retriever).to receive(:retrieve).and_return([])

      result = pipeline.run("test query")

      expect(result).not_to be_success
      expect(result.error).to eq("No search results found")
    end

    it "returns error when generation fails" do
      failed_generation = Homunculus::SAG::GenerationResult.new(
        query: "test query", response: nil, snippets_used: 0, prompt_chars: 0, error: "LLM timeout"
      )
      allow(generator).to receive(:generate).and_return(failed_generation)

      result = pipeline.run("test query")

      expect(result).not_to be_success
      expect(result.error).to eq("LLM timeout")
    end

    it "deduplicates snippets by URL across sub-queries" do
      multi_analysis = Homunculus::SAG::QueryAnalysis.new(
        intent: :research, sub_queries: ["query 1", "query 2"], original: "test"
      )
      allow(analyzer).to receive(:analyze).and_return(multi_analysis)
      allow(retriever).to receive(:retrieve).with(query: "query 1").and_return([snippet_a, snippet_b])
      allow(retriever).to receive(:retrieve).with(query: "query 2").and_return([snippet_a])

      pipeline.run("test")

      expect(reranker).to have_received(:rerank) do |args|
        urls = args[:snippets].map(&:url)
        expect(urls).to eq(["https://a.com", "https://b.com"])
      end
    end

    it "reassigns ranks 1-N after dedup" do
      pipeline.run("test query")

      expect(reranker).to have_received(:rerank) do |args|
        ranks = args[:snippets].map(&:rank)
        expect(ranks).to eq([1, 2])
      end
    end

    it "caps total snippets at MAX_TOTAL_SNIPPETS" do
      many_snippets = (1..12).map do |i|
        Homunculus::SAG::Snippet.from_search(
          url: "https://example.com/#{i}", title: "T#{i}", body: "B#{i}", rank: i
        )
      end
      allow(retriever).to receive(:retrieve).and_return(many_snippets)

      pipeline.run("test query")

      expect(reranker).to have_received(:rerank) do |args|
        expect(args[:snippets].size).to eq(described_class::MAX_TOTAL_SNIPPETS)
      end
    end

    it "handles unexpected exceptions gracefully" do
      allow(analyzer).to receive(:analyze).and_raise(RuntimeError, "unexpected")

      result = pipeline.run("test query")

      expect(result).not_to be_success
      expect(result.error).to eq("unexpected")
    end
  end
end

RSpec.describe Homunculus::SAG::PipelineResult do
  describe ".error" do
    it "creates a failed result" do
      result = described_class.error("q", "something broke")

      expect(result).not_to be_success
      expect(result.error).to eq("something broke")
      expect(result.query).to eq("q")
      expect(result.snippets).to be_empty
      expect(result.cited_urls).to be_empty
      expect(result.confidence).to eq(0.0)
    end
  end

  describe "#well_supported?" do
    it "returns true when successful with good confidence and citations" do
      result = described_class.new(
        query: "q", analysis: nil, snippets: [], response: "yes",
        cited_urls: ["https://a.com"], confidence: 0.6, error: nil
      )
      expect(result).to be_well_supported
    end

    it "returns false when confidence is low" do
      result = described_class.new(
        query: "q", analysis: nil, snippets: [], response: "yes",
        cited_urls: ["https://a.com"], confidence: 0.3, error: nil
      )
      expect(result).not_to be_well_supported
    end

    it "returns false when no citations" do
      result = described_class.new(
        query: "q", analysis: nil, snippets: [], response: "yes",
        cited_urls: [], confidence: 0.8, error: nil
      )
      expect(result).not_to be_well_supported
    end

    it "returns false on error" do
      result = described_class.error("q", "fail")
      expect(result).not_to be_well_supported
    end
  end
end
