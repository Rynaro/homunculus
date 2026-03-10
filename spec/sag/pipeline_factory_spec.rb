# frozen_string_literal: true

require_relative "../../lib/homunculus/sag/llm_adapter"
require_relative "../../lib/homunculus/sag/pipeline_factory"

RSpec.describe Homunculus::SAG::PipelineFactory do
  let(:sag_config) do
    Struct.new(:searxng_url, :searxng_categories, :top_n_results, :searxng_timeout, :max_tokens, keyword_init: true).new(
      searxng_url: "http://localhost:8888",
      searxng_categories: ["general"],
      top_n_results: 5,
      searxng_timeout: 10,
      max_tokens: 512
    )
  end

  let(:llm_adapter) { instance_double(Homunculus::SAG::LLMAdapter) }
  let(:factory) { described_class.new(config: sag_config, llm_adapter: llm_adapter) }

  describe "#call" do
    it "returns a Pipeline instance" do
      pipeline = factory.call

      expect(pipeline).to be_a(Homunculus::SAG::Pipeline)
    end

    it "returns a new pipeline each invocation" do
      p1 = factory.call
      p2 = factory.call

      expect(p1).not_to equal(p2)
    end

    it "accepts deep_fetch override" do
      pipeline = factory.call(deep_fetch: true)

      expect(pipeline).to be_a(Homunculus::SAG::Pipeline)
    end
  end
end
