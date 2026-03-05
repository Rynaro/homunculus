# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/homunculus/sag/snippet"
require_relative "../../lib/homunculus/sag/grounded_generator"

RSpec.describe Homunculus::SAG::GroundedGenerator do
  subject(:generator) { described_class.new(llm: llm) }

  let(:llm) { double("LLM") } # rubocop:disable RSpec/VerifiedDoubles

  let(:snippet) do
    Homunculus::SAG::Snippet.from_search(
      url: "https://example.com/ruby",
      title: "Ruby Programming Language",
      body: "Ruby is a dynamic, open source programming language.",
      rank: 1
    )
  end

  describe "#generate" do
    context "when the LLM call succeeds" do
      before do
        allow(llm).to receive(:call).and_return("Some answer [1].")
      end

      it "returns a successful GenerationResult" do
        result = generator.generate(query: "What is Ruby?", snippets: [snippet])

        expect(result).to be_a(Homunculus::SAG::GenerationResult)
        expect(result.success?).to be true
        expect(result.error).to be_nil
      end

      it "forwards the query into the result" do
        result = generator.generate(query: "What is Ruby?", snippets: [snippet])

        expect(result.query).to eq("What is Ruby?")
      end

      it "populates the response from the LLM" do
        result = generator.generate(query: "What is Ruby?", snippets: [snippet])

        expect(result.response).to eq("Some answer [1].")
      end

      it "records the number of snippets used" do
        result = generator.generate(query: "What is Ruby?", snippets: [snippet])

        expect(result.snippets_used).to eq(1)
      end

      it "records a positive prompt_chars value" do
        result = generator.generate(query: "What is Ruby?", snippets: [snippet])

        expect(result.prompt_chars).to be > 0
      end

      it "calls the LLM with max_tokens from the constructor default" do
        generator.generate(query: "What is Ruby?", snippets: [snippet])

        expect(llm).to have_received(:call).with(anything, max_tokens: 1024)
      end

      it "calls the LLM with max_tokens override when given" do
        fast_generator = described_class.new(llm: llm, max_tokens: 256)
        fast_generator.generate(query: "What is Ruby?", snippets: [snippet])

        expect(llm).to have_received(:call).with(anything, max_tokens: 256)
      end
    end

    context "when snippets exceed MAX_SNIPPETS_IN_PROMPT" do
      let(:many_snippets) do
        (1..10).map do |i|
          Homunculus::SAG::Snippet.from_search(
            url: "https://example.com/#{i}",
            title: "Title #{i}",
            body: "Body #{i}",
            rank: i
          )
        end
      end

      before do
        allow(llm).to receive(:call).and_return("answer")
      end

      it "uses at most MAX_SNIPPETS_IN_PROMPT snippets" do
        result = generator.generate(query: "test", snippets: many_snippets)

        expect(result.snippets_used).to eq(Homunculus::SAG::GroundedGenerator::MAX_SNIPPETS_IN_PROMPT)
      end

      it "only includes the first MAX_SNIPPETS_IN_PROMPT snippets in the prompt" do
        captured_prompt = nil
        allow(llm).to receive(:call) do |prompt, **|
          captured_prompt = prompt
          "answer"
        end

        generator.generate(query: "test", snippets: many_snippets)

        expect(captured_prompt).to include("Title 6")
        expect(captured_prompt).not_to include("Title 7")
      end
    end

    context "when a snippet body exceeds MAX_SNIPPET_CHARS" do
      let(:long_body) { "x" * 1200 }
      let(:long_snippet) do
        Homunculus::SAG::Snippet.from_search(
          url: "https://example.com/long",
          title: "Long Article",
          body: long_body,
          rank: 1
        )
      end

      before do
        allow(llm).to receive(:call).and_return("truncated answer")
      end

      it "truncates the body to MAX_SNIPPET_CHARS in the prompt" do
        captured_prompt = nil
        allow(llm).to receive(:call) do |prompt, **|
          captured_prompt = prompt
          "truncated answer"
        end

        generator.generate(query: "test", snippets: [long_snippet])

        # The full 1200-char body must not appear; only 800 chars allowed
        expect(captured_prompt).not_to include(long_body)
        expect(captured_prompt).to include("x" * Homunculus::SAG::GroundedGenerator::MAX_SNIPPET_CHARS)
      end
    end

    context "when the LLM raises an error" do
      before do
        allow(llm).to receive(:call).and_raise(StandardError, "connection timeout")
      end

      it "returns a GenerationResult with error set" do
        result = generator.generate(query: "What is Ruby?", snippets: [snippet])

        expect(result.success?).to be false
        expect(result.error).to eq("connection timeout")
      end

      it "returns nil response on failure" do
        result = generator.generate(query: "What is Ruby?", snippets: [snippet])

        expect(result.response).to be_nil
      end

      it "returns zero snippets_used on failure" do
        result = generator.generate(query: "What is Ruby?", snippets: [snippet])

        expect(result.snippets_used).to eq(0)
      end

      it "returns zero prompt_chars on failure" do
        result = generator.generate(query: "What is Ruby?", snippets: [snippet])

        expect(result.prompt_chars).to eq(0)
      end

      it "preserves the original query on failure" do
        result = generator.generate(query: "What is Ruby?", snippets: [snippet])

        expect(result.query).to eq("What is Ruby?")
      end
    end
  end

  describe "GenerationResult#success?" do
    it "returns true when error is nil" do
      result = Homunculus::SAG::GenerationResult.new(
        query: "q",
        response: "r",
        snippets_used: 1,
        prompt_chars: 100,
        error: nil
      )

      expect(result.success?).to be true
    end

    it "returns false when error is present" do
      result = Homunculus::SAG::GenerationResult.new(
        query: "q",
        response: nil,
        snippets_used: 0,
        prompt_chars: 0,
        error: "boom"
      )

      expect(result.success?).to be false
    end
  end
end
