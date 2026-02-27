# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Agent::Context::Compactor do
  let(:context_config) do
    Homunculus::ContextConfig.new(
      compaction_enabled: true,
      compaction_soft_threshold: 0.75,
      compaction_reserve_floor: 500,
      compaction_preserved_turns: 3
    )
  end

  let(:budget) { Homunculus::Agent::Context::Budget.new(context_window: 1000, config: context_config) }
  let(:compressor) { Homunculus::Agent::Context::Compressor.new }

  let(:compactor) do
    described_class.new(config: context_config, budget: budget, compressor: compressor)
  end

  def make_messages(count)
    count.times.map do |i|
      role = i.even? ? "user" : "assistant"
      { role: role, content: "Message #{i} " + ("content " * 10) }
    end
  end

  describe "#needs_compaction?" do
    context "when compaction is disabled" do
      let(:disabled_config) do
        Homunculus::ContextConfig.new(compaction_enabled: false)
      end
      let(:disabled_compactor) do
        described_class.new(config: disabled_config, budget: budget, compressor: compressor)
      end

      it "returns false" do
        messages = make_messages(50)
        expect(disabled_compactor.needs_compaction?(messages)).to be false
      end
    end

    context "when flush is already in progress" do
      it "returns false" do
        compactor.flush_message # sets flush_in_progress
        messages = make_messages(50)
        expect(compactor.needs_compaction?(messages)).to be false
      end
    end

    context "when messages are under threshold" do
      it "returns false" do
        messages = [{ role: "user", content: "Hello" }]
        expect(compactor.needs_compaction?(messages)).to be false
      end
    end

    context "when messages are at or above threshold" do
      it "returns true" do
        # conversation budget = 1000 * 0.40 = 400 tokens, threshold = 400 * 0.75 = 300
        messages = make_messages(30)
        expect(compactor.needs_compaction?(messages)).to be true
      end
    end
  end

  describe "#flush_message" do
    it "returns a user-role message with flush marker" do
      msg = compactor.flush_message
      expect(msg[:role]).to eq(:user)
      expect(msg[:content]).to include(described_class::FLUSH_MARKER)
    end

    it "sets flush_in_progress" do
      expect(compactor.flush_in_progress?).to be false
      compactor.flush_message
      expect(compactor.flush_in_progress?).to be true
    end
  end

  describe "#compact" do
    let(:messages) do
      [
        { role: "user", content: "First question #{"padding " * 20}" },
        { role: "assistant", content: "First answer #{"padding " * 20}" },
        { role: "user", content: "Second question #{"padding " * 20}" },
        { role: "assistant", content: "Second answer #{"padding " * 20}" },
        { role: "user", content: "Third question #{"padding " * 20}" },
        { role: "assistant", content: "Third answer #{"padding " * 20}" },
        { role: "user", content: "Fourth question" },
        { role: "assistant", content: "Fourth answer" },
        { role: "user", content: "Fifth question" },
        { role: "assistant", content: "Fifth answer" }
      ]
    end

    it "preserves the last N assistant messages" do
      result = compactor.compact(messages)
      assistant_msgs = result.select { |m| m[:role]&.to_s == "assistant" || m["role"]&.to_s == "assistant" }
      expect(assistant_msgs.length).to be >= 3
    end

    it "prepends a compacted context summary for older messages" do
      result = compactor.compact(messages)
      summary = result.find { |m| (m[:content] || m["content"]).to_s.include?("[Compacted context]") }
      expect(summary).not_to be_nil
    end

    it "strips flush artifacts from recent messages" do
      messages_with_flush = messages + [
        { role: "user", content: described_class::FLUSH_INSTRUCTION },
        { role: "assistant", content: "I saved the facts." }
      ]
      result = compactor.compact(messages_with_flush)
      flush_msgs = result.select { |m| (m[:content] || m["content"]).to_s.include?(described_class::FLUSH_MARKER) }
      expect(flush_msgs).to be_empty
    end

    it "handles empty older messages gracefully" do
      # Only 3 assistant messages — nothing to compact (all preserved)
      short_messages = [
        { role: "user", content: "Q1" },
        { role: "assistant", content: "A1" },
        { role: "user", content: "Q2" },
        { role: "assistant", content: "A2" },
        { role: "user", content: "Q3" },
        { role: "assistant", content: "A3" }
      ]
      result = compactor.compact(short_messages)
      expect(result).to eq(short_messages)
    end

    it "resets state after compaction" do
      compactor.flush_message # sets flush_in_progress
      compactor.compact(messages)
      expect(compactor.flush_in_progress?).to be false
    end
  end

  describe "#reset!" do
    it "clears all state flags" do
      compactor.flush_message
      expect(compactor.flush_in_progress?).to be true
      compactor.reset!
      expect(compactor.flush_in_progress?).to be false
    end
  end
end
