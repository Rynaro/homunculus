# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::SAGConfig do
  describe "defaults" do
    subject(:config) { described_class.new({}) }

    it "defaults enabled to false" do
      expect(config.enabled).to be false
    end

    it "defaults searxng_url" do
      expect(config.searxng_url).to eq("http://localhost:8888")
    end

    it "defaults searxng_categories" do
      expect(config.searxng_categories).to eq(["general"])
    end

    it "defaults top_n_results to 5" do
      expect(config.top_n_results).to eq(5)
    end

    it "defaults deep_fetch to false" do
      expect(config.deep_fetch).to be false
    end

    it "defaults reranking_strategy to embedding" do
      expect(config.reranking_strategy).to eq("embedding")
    end

    it "defaults max_tokens to 1024" do
      expect(config.max_tokens).to eq(1024)
    end

    it "defaults searxng_timeout to 15" do
      expect(config.searxng_timeout).to eq(15)
    end
  end

  describe "overrides" do
    it "accepts custom values" do
      config = described_class.new(
        enabled: true,
        searxng_url: "http://search.local:9999",
        top_n_results: 10,
        deep_fetch: true,
        reranking_strategy: "positional",
        max_tokens: 2048,
        searxng_timeout: 30
      )

      expect(config.enabled).to be true
      expect(config.searxng_url).to eq("http://search.local:9999")
      expect(config.top_n_results).to eq(10)
    end
  end

  describe "integration with Config" do
    it "is accessible via Config#sag" do
      config = Homunculus::Config.load("config/default.toml")

      expect(config.sag).to be_a(described_class)
      expect(config.sag.enabled).to be true
    end
  end
end
