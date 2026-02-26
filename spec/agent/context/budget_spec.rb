# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Agent::Context::Budget do
  describe "#tokens_for" do
    context "with default percentages" do
      subject(:budget) { described_class.new(context_window: 32_768) }

      it "allocates 30% to system_prompt" do
        expect(budget.tokens_for(:system_prompt)).to eq(9830)
      end

      it "allocates 10% to skills" do
        expect(budget.tokens_for(:skills)).to eq(3276)
      end

      it "allocates 15% to memory" do
        expect(budget.tokens_for(:memory)).to eq(4915)
      end

      it "allocates 40% to conversation" do
        expect(budget.tokens_for(:conversation)).to eq(13_107)
      end

      it "allocates 5% to reserve" do
        expect(budget.tokens_for(:reserve)).to eq(1638)
      end

      it "raises ArgumentError for unknown section" do
        expect { budget.tokens_for(:unknown) }.to raise_error(ArgumentError, /Unknown section/)
      end
    end

    context "with custom config percentages" do
      subject(:budget) { described_class.new(context_window: 8192, config: config) }

      let(:config) do
        Homunculus::ContextConfig.new(
          system_prompt_pct: 0.20,
          skills_pct: 0.05,
          memory_pct: 0.20,
          conversation_pct: 0.50,
          reserve_pct: 0.05
        )
      end

      it "respects custom system_prompt percentage" do
        expect(budget.tokens_for(:system_prompt)).to eq(1638)
      end

      it "respects custom conversation percentage" do
        expect(budget.tokens_for(:conversation)).to eq(4096)
      end
    end

    context "with small context window (whisper tier 8K)" do
      subject(:budget) { described_class.new(context_window: 8192) }

      it "gives proportionally smaller budgets" do
        expect(budget.tokens_for(:conversation)).to eq(3276)
      end
    end
  end
end
