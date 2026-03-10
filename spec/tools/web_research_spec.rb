# frozen_string_literal: true

require_relative "../../lib/homunculus/tools/base"
require_relative "../../lib/homunculus/tools/web_research"

RSpec.describe Homunculus::Tools::WebResearch do
  subject(:tool) { described_class.new(pipeline_factory: pipeline_factory) }

  let(:pipeline) { instance_double(Homunculus::SAG::Pipeline) }
  let(:pipeline_factory) { ->(**_kwargs) { pipeline } }
  let(:session) { nil }

  describe "tool metadata" do
    it "has the correct tool name" do
      expect(tool.name).to eq("web_research")
    end

    it "does not require confirmation" do
      expect(tool.requires_confirmation).to be false
    end

    it "has untrusted trust level" do
      expect(tool.trust_level).to eq(:untrusted)
    end

    it "positions itself as the preferred factual lookup tool" do
      expect(tool.description).to include("PREFERRED tool for factual questions")
      expect(tool.description).to include("Use BEFORE web_fetch")
    end

    it "requires query parameter" do
      expect(tool.parameters[:query][:required]).to be true
    end
  end

  describe "#execute" do
    context "when pipeline succeeds" do
      let(:success_result) do
        Homunculus::SAG::PipelineResult.new(
          query: "what is Ruby?",
          analysis: nil,
          snippets: [
            Homunculus::SAG::Snippet.from_search(url: "https://ruby-lang.org", title: "Ruby", body: "A language", rank: 1)
          ],
          response: "Ruby is a programming language [1].",
          cited_urls: ["https://ruby-lang.org"],
          confidence: 0.8,
          error: nil
        )
      end

      before do
        allow(pipeline).to receive(:run).and_return(success_result)
      end

      it "returns a successful result" do
        result = tool.execute(arguments: { query: "what is Ruby?" }, session: session)

        expect(result.success).to be true
      end

      it "includes the response text" do
        result = tool.execute(arguments: { query: "what is Ruby?" }, session: session)

        expect(result.output).to include("Ruby is a programming language [1].")
      end

      it "includes sources section" do
        result = tool.execute(arguments: { query: "what is Ruby?" }, session: session)

        expect(result.output).to include("Sources:")
        expect(result.output).to include("[1] https://ruby-lang.org")
      end

      it "includes confidence label" do
        result = tool.execute(arguments: { query: "what is Ruby?" }, session: session)

        expect(result.output).to include("Confidence: high (80%)")
      end

      it "includes metadata" do
        result = tool.execute(arguments: { query: "what is Ruby?" }, session: session)

        expect(result.metadata[:confidence]).to eq(0.8)
        expect(result.metadata[:cited_urls]).to eq(["https://ruby-lang.org"])
        expect(result.metadata[:snippet_count]).to eq(1)
      end
    end

    context "when pipeline fails" do
      let(:error_result) do
        Homunculus::SAG::PipelineResult.error("what is Ruby?", "No search results found")
      end

      before do
        allow(pipeline).to receive(:run).and_return(error_result)
      end

      it "returns a failure result" do
        result = tool.execute(arguments: { query: "what is Ruby?" }, session: session)

        expect(result.success).to be false
        expect(result.error).to include("No search results found")
      end
    end

    context "with missing query" do
      it "returns error for nil query" do
        result = tool.execute(arguments: {}, session: session)

        expect(result.success).to be false
        expect(result.error).to include("Missing required parameter: query")
      end

      it "returns error for empty query" do
        result = tool.execute(arguments: { query: "  " }, session: session)

        expect(result.success).to be false
        expect(result.error).to include("Missing required parameter: query")
      end
    end

    context "with deep_fetch parameter" do
      before do
        allow(pipeline).to receive(:run).and_return(
          Homunculus::SAG::PipelineResult.new(
            query: "q", analysis: nil, snippets: [], response: "answer",
            cited_urls: [], confidence: 0.5, error: nil
          )
        )
      end

      it "passes deep_fetch true to factory" do
        factory = instance_double(Proc)
        allow(factory).to receive(:call).and_return(pipeline)
        deep_tool = described_class.new(pipeline_factory: factory)

        deep_tool.execute(arguments: { query: "test", deep_fetch: "true" }, session: session)

        expect(factory).to have_received(:call).with(deep_fetch: true)
      end

      it "passes deep_fetch false to factory by default" do
        factory = instance_double(Proc)
        allow(factory).to receive(:call).and_return(pipeline)
        deep_tool = described_class.new(pipeline_factory: factory)

        deep_tool.execute(arguments: { query: "test" }, session: session)

        expect(factory).to have_received(:call).with(deep_fetch: false)
      end
    end

    context "with confidence levels" do
      it "labels medium confidence" do
        allow(pipeline).to receive(:run).and_return(
          Homunculus::SAG::PipelineResult.new(
            query: "q", analysis: nil, snippets: [], response: "answer",
            cited_urls: [], confidence: 0.5, error: nil
          )
        )

        result = tool.execute(arguments: { query: "test" }, session: session)

        expect(result.output).to include("Confidence: medium (50%)")
      end

      it "labels low confidence" do
        allow(pipeline).to receive(:run).and_return(
          Homunculus::SAG::PipelineResult.new(
            query: "q", analysis: nil, snippets: [], response: "answer",
            cited_urls: [], confidence: 0.2, error: nil
          )
        )

        result = tool.execute(arguments: { query: "test" }, session: session)

        expect(result.output).to include("Confidence: low (20%)")
      end
    end

    context "when pipeline raises exception" do
      before do
        allow(pipeline).to receive(:run).and_raise(RuntimeError, "connection refused")
      end

      it "returns a failure result" do
        result = tool.execute(arguments: { query: "test" }, session: session)

        expect(result.success).to be false
        expect(result.error).to include("connection refused")
      end
    end
  end
end
