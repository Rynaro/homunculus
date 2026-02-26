# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Agent::Context::Window do
  let(:budget) { Homunculus::Agent::Context::Budget.new(context_window: 1000) }
  let(:compressor) { Homunculus::Agent::Context::Compressor.new }

  describe "#apply" do
    context "when messages fit within budget" do
      let(:messages) do
        [
          { role: "user", content: "Hello" },
          { role: "assistant", content: "Hi there!" }
        ]
      end

      it "returns all messages unchanged" do
        window = described_class.new(budget: budget)
        result = window.apply(messages)

        expect(result).to eq(messages)
      end
    end

    context "when messages exceed budget" do
      let(:long_messages) do
        30.times.map do |i|
          role = i.even? ? "user" : "assistant"
          { role: role, content: "This is message number #{i} " + ("with extra content " * 20) }
        end
      end

      it "reduces message count" do
        window = described_class.new(budget: budget)
        result = window.apply(long_messages)

        expect(result.length).to be < long_messages.length
      end

      it "keeps recent messages" do
        window = described_class.new(budget: budget)
        result = window.apply(long_messages)
        last_original = long_messages.last[:content]

        expect(result.last[:content]).to eq(last_original)
      end

      it "prepends a summary message when compressor is available" do
        window = described_class.new(budget: budget, compressor: compressor)
        result = window.apply(long_messages)

        summary = result.find { |m| (m[:content] || "").include?("[Conversation summary]") }
        expect(summary).not_to be_nil
        expect(summary[:role]).to eq("system")
      end

      it "works without compressor (simple truncation)" do
        window = described_class.new(budget: budget)
        result = window.apply(long_messages)

        expect(result.length).to be < long_messages.length
        summary = result.find { |m| (m[:content] || "").include?("[Conversation summary]") }
        expect(summary).not_to be_nil
      end
    end

    context "with nil or empty messages" do
      it "returns nil messages as-is" do
        window = described_class.new(budget: budget)
        expect(window.apply(nil)).to be_nil
      end

      it "returns empty array as-is" do
        window = described_class.new(budget: budget)
        expect(window.apply([])).to eq([])
      end
    end
  end
end
