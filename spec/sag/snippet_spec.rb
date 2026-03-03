# frozen_string_literal: true

require_relative "../../lib/homunculus/sag/snippet"

RSpec.describe Homunculus::SAG::Snippet do
  describe ".from_search" do
    subject(:snippet) { described_class.from_search(url: "https://example.com", title: "Example", body: "Some body text", rank: 1) }

    it "sets source to :search" do
      expect(snippet.source).to eq(:search)
    end

    it "sets score to 0.0" do
      expect(snippet.score).to eq(0.0)
    end

    it "preserves url, title, body, and rank" do
      expect(snippet.url).to eq("https://example.com")
      expect(snippet.title).to eq("Example")
      expect(snippet.body).to eq("Some body text")
      expect(snippet.rank).to eq(1)
    end
  end

  describe ".from_deep_fetch" do
    subject(:snippet) { described_class.from_deep_fetch(url: "https://deep.com", title: "Deep", body: "Deep body", rank: 3) }

    it "sets source to :deep_fetch" do
      expect(snippet.source).to eq(:deep_fetch)
    end

    it "sets score to 0.0" do
      expect(snippet.score).to eq(0.0)
    end

    it "preserves url, title, body, and rank" do
      expect(snippet.url).to eq("https://deep.com")
      expect(snippet.title).to eq("Deep")
      expect(snippet.body).to eq("Deep body")
      expect(snippet.rank).to eq(3)
    end
  end

  describe "#with_score" do
    let(:original) { described_class.from_search(url: "https://example.com", title: "Title", body: "Body", rank: 2) }

    it "returns a new Snippet with the updated score" do
      updated = original.with_score(0.95)

      expect(updated.score).to eq(0.95)
    end

    it "does not mutate the original snippet" do
      original.with_score(0.95)

      expect(original.score).to eq(0.0)
    end

    it "preserves all other attributes on the returned snippet" do
      updated = original.with_score(0.75)

      expect(updated.url).to eq(original.url)
      expect(updated.title).to eq(original.title)
      expect(updated.body).to eq(original.body)
      expect(updated.source).to eq(original.source)
      expect(updated.rank).to eq(original.rank)
    end

    it "returns a different object than the original" do
      updated = original.with_score(0.5)

      expect(updated).not_to equal(original)
    end
  end

  describe "#text_for_embedding" do
    subject(:snippet) { described_class.from_search(url: "https://example.com", title: "My Title", body: "My Body", rank: 1) }

    it "returns title and body separated by a space" do
      expect(snippet.text_for_embedding).to eq("My Title My Body")
    end
  end

  describe "#citation_label" do
    it "returns [N] where N is the rank" do
      snippet = described_class.from_search(url: "https://example.com", title: "T", body: "B", rank: 5)

      expect(snippet.citation_label).to eq("[5]")
    end

    it "works for rank 1" do
      snippet = described_class.from_search(url: "https://example.com", title: "T", body: "B", rank: 1)

      expect(snippet.citation_label).to eq("[1]")
    end
  end

  describe "immutability" do
    subject(:snippet) { described_class.from_search(url: "https://example.com", title: "T", body: "B", rank: 1) }

    it "is frozen" do
      expect(snippet).to be_frozen
    end

    it "raises FrozenError when attempting to set an attribute" do
      expect { snippet.instance_variable_set(:@url, "mutated") }.to raise_error(FrozenError)
    end
  end
end
