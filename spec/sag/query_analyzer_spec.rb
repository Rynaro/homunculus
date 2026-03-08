# frozen_string_literal: true

require_relative "../../lib/homunculus/sag/query_analyzer"

RSpec.describe Homunculus::SAG::QueryAnalyzer do
  subject(:analyzer) { described_class.new }

  describe "#analyze" do
    context "when query matches factual patterns" do
      it "detects :factual intent for 'what is Ruby?'" do
        result = analyzer.analyze("what is Ruby?")
        expect(result.intent).to eq(:factual)
      end

      it "detects :factual intent for 'who is Matz?'" do
        result = analyzer.analyze("who is Matz?")
        expect(result.intent).to eq(:factual)
      end

      it "detects :factual intent for 'how many gems exist?'" do
        result = analyzer.analyze("how many gems exist?")
        expect(result.intent).to eq(:factual)
      end
    end

    context "when query matches comparison patterns" do
      it "detects :comparison intent for 'Ruby vs Python'" do
        result = analyzer.analyze("Ruby vs Python")
        expect(result.intent).to eq(:comparison)
      end

      it "detects :comparison intent for 'compare Rails and Django'" do
        result = analyzer.analyze("compare Rails and Django")
        expect(result.intent).to eq(:comparison)
      end

      it "detects :comparison intent for 'difference between threads and fibers'" do
        result = analyzer.analyze("difference between threads and fibers")
        expect(result.intent).to eq(:comparison)
      end
    end

    context "when query matches no specific pattern" do
      it "defaults to :research intent" do
        result = analyzer.analyze("best practices for building APIs")
        expect(result.intent).to eq(:research)
      end
    end

    context "with QueryAnalysis struct" do
      it "stores intent, sub_queries, and original on the result" do
        result = analyzer.analyze("what is Ruby?")

        expect(result.intent).to eq(:factual)
        expect(result.sub_queries).to eq(["what is Ruby?"])
        expect(result.original).to eq("what is Ruby?")
      end
    end
  end

  describe "sub-query decomposition" do
    context "for factual queries" do
      it "passes through as a single sub-query without calling LLM" do
        llm = instance_double(Proc)
        expect(llm).not_to receive(:call)

        factual_analyzer = described_class.new(llm: llm)
        result = factual_analyzer.analyze("what is Ruby?")

        expect(result.sub_queries).to eq(["what is Ruby?"])
      end
    end

    context "for research queries with no LLM" do
      it "passes through as a single sub-query" do
        result = analyzer.analyze("best practices for building APIs")
        expect(result.sub_queries).to eq(["best practices for building APIs"])
      end
    end

    context "for research queries with an LLM" do
      let(:llm) { instance_double(Proc) }
      let(:llm_analyzer) { described_class.new(llm: llm) }

      it "decomposes into multiple sub-queries" do
        allow(llm).to receive(:call).and_return("sub query 1\nsub query 2")

        result = llm_analyzer.analyze("best practices for building APIs")

        expect(result.sub_queries).to eq(["sub query 1", "sub query 2"])
      end

      it "caps sub-queries at MAX_SUB_QUERIES" do
        five_queries = (1..5).map { |i| "sub query #{i}" }.join("\n")
        allow(llm).to receive(:call).and_return(five_queries)

        result = llm_analyzer.analyze("comprehensive guide to everything")

        expect(result.sub_queries.length).to eq(described_class::MAX_SUB_QUERIES)
      end

      it "falls back to original query when LLM raises an error" do
        allow(llm).to receive(:call).and_raise(StandardError, "connection refused")

        result = llm_analyzer.analyze("best practices for building APIs")

        expect(result.sub_queries).to eq(["best practices for building APIs"])
      end

      it "falls back to original when LLM returns empty response" do
        allow(llm).to receive(:call).and_return("   \n\n  ")

        result = llm_analyzer.analyze("best practices for building APIs")

        expect(result.sub_queries).to eq(["best practices for building APIs"])
      end
    end

    context "for comparison queries with an LLM" do
      let(:llm) { instance_double(Proc) }
      let(:llm_analyzer) { described_class.new(llm: llm) }

      it "uses LLM to decompose comparison queries" do
        allow(llm).to receive(:call).and_return("Ruby features\nPython features")

        result = llm_analyzer.analyze("Ruby vs Python")

        expect(result.sub_queries).to eq(["Ruby features", "Python features"])
      end
    end
  end
end
