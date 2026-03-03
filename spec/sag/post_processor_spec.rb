# frozen_string_literal: true

require_relative "../../lib/homunculus/sag/snippet"
require_relative "../../lib/homunculus/sag/post_processor"

RSpec.describe Homunculus::SAG::PostProcessor do
  subject(:processor) { described_class.new }

  let(:high_score_snippet) do
    Homunculus::SAG::Snippet.from_search(url: "https://example.com/1", title: "First", body: "Body one", rank: 1)
                            .with_score(0.8)
  end
  let(:low_score_snippet) do
    Homunculus::SAG::Snippet.from_search(url: "https://example.com/2", title: "Second", body: "Body two", rank: 2)
                            .with_score(0.6)
  end
  let(:top_score_snippet) do
    Homunculus::SAG::Snippet.from_search(url: "https://example.com/3", title: "Third", body: "Body three", rank: 3)
                            .with_score(0.9)
  end

  describe "#process" do
    context "when response is nil" do
      it "returns an empty result" do
        result = processor.process(response: nil, snippets: [high_score_snippet])

        expect(result.text).to eq("")
        expect(result.cited_snippets).to be_empty
        expect(result.orphaned_citations).to be_empty
        expect(result.confidence).to eq(0.0)
        expect(result.citation_count).to eq(0)
      end
    end

    context "when response is an empty string" do
      it "returns an empty result" do
        result = processor.process(response: "", snippets: [high_score_snippet])

        expect(result.text).to eq("")
        expect(result.citation_count).to eq(0)
        expect(result.confidence).to eq(0.0)
      end
    end

    context "when response contains only whitespace" do
      it "returns an empty result" do
        result = processor.process(response: "   \n  ", snippets: [high_score_snippet])

        expect(result.citation_count).to eq(0)
        expect(result.confidence).to eq(0.0)
      end
    end

    context "when response cites a known snippet rank" do
      it "includes the matching snippet in cited_snippets" do
        result = processor.process(
          response: "According to [1] this is true.",
          snippets: [high_score_snippet, low_score_snippet]
        )

        expect(result.cited_snippets).to include(high_score_snippet)
        expect(result.cited_snippets).not_to include(low_score_snippet)
      end

      it "sets citation_count to the number of unique cited snippets" do
        result = processor.process(
          response: "See [1] and [2] for details.",
          snippets: [high_score_snippet, low_score_snippet]
        )

        expect(result.citation_count).to eq(2)
      end

      it "preserves the response text unchanged" do
        response = "Ruby is great [1]."
        result = processor.process(response: response, snippets: [high_score_snippet])

        expect(result.text).to eq(response)
      end
    end

    context "when response contains an orphaned citation" do
      it "adds the rank to orphaned_citations" do
        result = processor.process(response: "See [99] for more.", snippets: [high_score_snippet])

        expect(result.orphaned_citations).to include(99)
      end

      it "does not add the rank to cited_snippets" do
        result = processor.process(response: "See [99] for more.", snippets: [high_score_snippet])

        expect(result.cited_snippets).to be_empty
      end
    end

    context "when response mixes valid and orphaned citations" do
      it "separates cited snippets from orphaned ranks" do
        result = processor.process(response: "See [1] and [99].", snippets: [high_score_snippet])

        expect(result.cited_snippets).to eq([high_score_snippet])
        expect(result.orphaned_citations).to eq([99])
      end
    end

    context "when the same citation rank appears multiple times" do
      it "deduplicates cited_snippets by rank" do
        result = processor.process(
          response: "See [1] and also [1] again.",
          snippets: [high_score_snippet]
        )

        expect(result.cited_snippets.size).to eq(1)
        expect(result.cited_snippets).to eq([high_score_snippet])
      end

      it "sets citation_count to 1 for the deduplicated snippet" do
        result = processor.process(
          response: "[1] was mentioned [1] twice.",
          snippets: [high_score_snippet]
        )

        expect(result.citation_count).to eq(1)
      end
    end

    context "when the response has no citations" do
      it "returns empty cited_snippets" do
        result = processor.process(
          response: "No citations here.",
          snippets: [high_score_snippet, low_score_snippet]
        )

        expect(result.cited_snippets).to be_empty
      end

      it "returns empty orphaned_citations" do
        result = processor.process(response: "No citations here.", snippets: [high_score_snippet])

        expect(result.orphaned_citations).to be_empty
      end
    end

    context "when snippets list is empty" do
      it "treats all citations as orphaned" do
        result = processor.process(response: "See [1] for details.", snippets: [])

        expect(result.orphaned_citations).to include(1)
        expect(result.cited_snippets).to be_empty
      end
    end
  end

  describe "confidence computation" do
    it "returns 0.0 when no snippets are provided" do
      result = processor.process(response: "No references.", snippets: [])

      expect(result.confidence).to eq(0.0)
    end

    it "computes 0.6 * citation_ratio + 0.4 * avg_score when all snippets cited" do
      # citation_ratio = 1/1 = 1.0, avg_score = 0.8
      # confidence = 0.6 * 1.0 + 0.4 * 0.8 = 0.92
      result = processor.process(response: "See [1].", snippets: [high_score_snippet])

      expect(result.confidence).to be_within(0.001).of(0.92)
    end

    it "scales citation_ratio by total snippet count" do
      # citation_ratio = 1/2 = 0.5, avg_score for cited (rank 1) = 0.8
      # confidence = 0.6 * 0.5 + 0.4 * 0.8 = 0.3 + 0.32 = 0.62
      result = processor.process(
        response: "See [1].",
        snippets: [high_score_snippet, low_score_snippet]
      )

      expect(result.confidence).to be_within(0.001).of(0.62)
    end

    it "returns 0.0 confidence when no snippets are cited" do
      # citation_ratio = 0/2 = 0.0, avg_score = 0.0
      result = processor.process(
        response: "No references here.",
        snippets: [high_score_snippet, low_score_snippet]
      )

      expect(result.confidence).to eq(0.0)
    end

    it "averages the scores of all cited snippets" do
      # Both cited: avg_score = (0.8 + 0.6) / 2 = 0.7
      # citation_ratio = 2/2 = 1.0
      # confidence = 0.6 * 1.0 + 0.4 * 0.7 = 0.6 + 0.28 = 0.88
      result = processor.process(
        response: "See [1] and [2].",
        snippets: [high_score_snippet, low_score_snippet]
      )

      expect(result.confidence).to be_within(0.001).of(0.88)
    end
  end
end

RSpec.describe Homunculus::SAG::ProcessedResult do
  let(:post_processor) { Homunculus::SAG::PostProcessor.new }
  let(:anchor_snippet) do
    Homunculus::SAG::Snippet.from_search(url: "https://example.com/1", title: "Anchor", body: "Body", rank: 1)
                            .with_score(0.8)
  end

  describe "#well_cited?" do
    it "returns true when citation_count is positive and no orphaned citations" do
      result = post_processor.process(response: "See [1].", snippets: [anchor_snippet])

      expect(result.well_cited?).to be true
    end

    it "returns false when citation_count is zero" do
      result = post_processor.process(response: "No citations.", snippets: [anchor_snippet])

      expect(result.well_cited?).to be false
    end

    it "returns false when there are orphaned citations" do
      result = post_processor.process(response: "See [1] and [99].", snippets: [anchor_snippet])

      expect(result.well_cited?).to be false
    end
  end

  describe "#high_confidence?" do
    it "returns true when confidence is exactly 0.7" do
      result = described_class.new(
        text: "response",
        cited_snippets: [],
        orphaned_citations: [],
        confidence: 0.7,
        citation_count: 0
      )

      expect(result.high_confidence?).to be true
    end

    it "returns true when confidence is above 0.7" do
      # citation_ratio = 1/1 = 1.0, avg_score = 0.8 -> confidence = 0.92
      result = post_processor.process(response: "See [1].", snippets: [anchor_snippet])

      expect(result.high_confidence?).to be true
    end

    it "returns false when confidence is below 0.7" do
      # citation_ratio = 1/2 = 0.5, avg_score = 0.8 -> confidence = 0.62
      low_snippet = Homunculus::SAG::Snippet.from_search(
        url: "https://example.com/2", title: "Low", body: "Body", rank: 2
      ).with_score(0.6)
      result = post_processor.process(response: "See [1].", snippets: [anchor_snippet, low_snippet])

      expect(result.high_confidence?).to be false
    end

    it "returns false when confidence is 0.0" do
      result = post_processor.process(response: nil, snippets: [anchor_snippet])

      expect(result.high_confidence?).to be false
    end
  end
end
