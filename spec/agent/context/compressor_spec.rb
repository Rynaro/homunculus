# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Agent::Context::Compressor do
  let(:messages) do
    [
      { role: "user", content: "What is Ruby?" },
      { role: "assistant", content: "Ruby is a dynamic programming language." },
      { role: "user", content: "How do I install gems?" },
      { role: "assistant", content: "Use the gem install command or Bundler." }
    ]
  end

  describe "#summarize" do
    context "without models_router (deterministic fallback)" do
      subject(:compressor) { described_class.new }

      it "extracts first lines of user messages" do
        result = compressor.summarize(messages, max_tokens: 100)

        expect(result).to include("What is Ruby?")
        expect(result).to include("How do I install gems?")
      end

      it "returns empty string for nil messages" do
        expect(compressor.summarize(nil, max_tokens: 100)).to eq("")
      end

      it "returns empty string for empty messages" do
        expect(compressor.summarize([], max_tokens: 100)).to eq("")
      end

      it "respects max_tokens limit" do
        long_messages = 50.times.map do |i|
          { role: "user", content: "This is message number #{i} with some extra text for length" }
        end

        result = compressor.summarize(long_messages, max_tokens: 20)
        tokens = Homunculus::Agent::Context::TokenCounter.estimate(result)
        expect(tokens).to be <= 20
      end
    end

    context "with models_router" do
      subject(:compressor) { described_class.new(models_router: mock_router) }

      let(:mock_router) { instance_double(Homunculus::Agent::Models::Router) }
      let(:mock_response) { double("Response", content: "Summary: User asked about Ruby and gem installation.") } # rubocop:disable RSpec/VerifiedDoubles

      before do
        allow(mock_router).to receive(:generate).and_return(mock_response)
      end

      it "uses LLM for summarization" do
        result = compressor.summarize(messages, max_tokens: 100)

        expect(result).to include("Ruby")
        expect(mock_router).to have_received(:generate)
      end

      it "passes whisper tier to router" do
        compressor.summarize(messages, max_tokens: 100)

        expect(mock_router).to have_received(:generate).with(hash_including(tier: :whisper))
      end

      it "falls back to deterministic on LLM error" do
        allow(mock_router).to receive(:generate).and_raise(StandardError, "Connection refused")

        result = compressor.summarize(messages, max_tokens: 100)
        expect(result).to include("What is Ruby?")
      end
    end
  end
end
