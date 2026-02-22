# frozen_string_literal: true

require "spec_helper"
require "sequel"

RSpec.describe Homunculus::Agent::BudgetTracker do
  let(:db) { Sequel.sqlite }
  let(:budget) { described_class.new(daily_limit_usd: 2.0, db:) }

  describe "#initialize" do
    it "creates the api_usage table" do
      budget # force lazy initialization
      expect(db.table_exists?(:api_usage)).to be true
    end

    it "is idempotent (can be called twice)" do
      expect { described_class.new(daily_limit_usd: 2.0, db:) }.not_to raise_error
    end
  end

  describe "#record_usage" do
    it "inserts a usage record into the database" do
      budget.record_usage(model: "claude-sonnet-4", input_tokens: 1000, output_tokens: 200)

      expect(db[:api_usage].count).to eq(1)
      row = db[:api_usage].first
      expect(row[:model]).to eq("claude-sonnet-4")
      expect(row[:input_tokens]).to eq(1000)
      expect(row[:output_tokens]).to eq(200)
      expect(row[:cost_usd]).to be > 0
    end

    it "returns the cost" do
      cost = budget.record_usage(model: "claude-sonnet-4", input_tokens: 1000, output_tokens: 200)

      # 1000 * 3/1M + 200 * 15/1M = 0.003 + 0.003 = 0.006
      expect(cost).to be_within(0.0001).of(0.006)
    end

    it "calculates cost correctly for large token counts" do
      cost = budget.record_usage(model: "claude-sonnet-4", input_tokens: 100_000, output_tokens: 10_000)

      # 100_000 * 3/1M + 10_000 * 15/1M = 0.30 + 0.15 = 0.45
      expect(cost).to be_within(0.001).of(0.45)
    end
  end

  describe "#spent_today" do
    it "returns 0 when no usage has been recorded" do
      expect(budget.spent_today).to eq(0.0)
    end

    it "sums today's usage" do
      budget.record_usage(model: "claude-sonnet-4", input_tokens: 1000, output_tokens: 200)
      budget.record_usage(model: "claude-sonnet-4", input_tokens: 2000, output_tokens: 400)

      # (1000*3 + 200*15)/1M + (2000*3 + 400*15)/1M = 0.006 + 0.012 = 0.018
      expect(budget.spent_today).to be_within(0.0001).of(0.018)
    end
  end

  describe "#remaining_today" do
    it "returns the full limit when nothing has been spent" do
      expect(budget.remaining_today).to eq(2.0)
    end

    it "returns the remaining amount after spending" do
      budget.record_usage(model: "claude-sonnet-4", input_tokens: 100_000, output_tokens: 10_000)

      # Spent 0.45, remaining 1.55
      expect(budget.remaining_today).to be_within(0.001).of(1.55)
    end
  end

  describe "#can_use_claude?" do
    it "returns true when budget is available" do
      expect(budget.can_use_claude?).to be true
    end

    it "returns true with custom estimated tokens" do
      expect(budget.can_use_claude?(estimated_tokens: 1000)).to be true
    end

    it "returns false when budget is exhausted" do
      # Spend enough to exhaust the $2 budget
      # Need: 2.0 / (3/1M) ≈ 666_667 input tokens
      budget.record_usage(model: "claude-sonnet-4", input_tokens: 500_000, output_tokens: 50_000)

      # Spent: 500_000*3/1M + 50_000*15/1M = 1.5 + 0.75 = 2.25
      expect(budget.can_use_claude?).to be false
    end

    it "returns false when remaining is less than estimated cost" do
      # Spend almost all the budget
      budget.record_usage(model: "claude-sonnet-4", input_tokens: 600_000, output_tokens: 5_000)

      # Spent: 600_000*3/1M + 5_000*15/1M = 1.80 + 0.075 = 1.875
      # Remaining: 0.125
      # Estimated cost of 4000 tokens: 4000*3/1M = 0.012
      # 0.125 > 0.012, so still true
      expect(budget.can_use_claude?).to be true

      # But with very large estimated tokens
      # 200_000 * 3/1M = 0.60 > 0.125
      expect(budget.can_use_claude?(estimated_tokens: 200_000)).to be false
    end
  end

  describe "#usage_summary" do
    it "returns a complete summary hash" do
      summary = budget.usage_summary

      expect(summary).to include(
        daily_limit_usd: 2.0,
        spent_today_usd: 0.0,
        remaining_usd: 2.0,
        can_use_claude: true
      )
    end

    it "reflects recorded usage" do
      budget.record_usage(model: "claude-sonnet-4", input_tokens: 100_000, output_tokens: 10_000)

      summary = budget.usage_summary
      expect(summary[:spent_today_usd]).to be > 0
      expect(summary[:remaining_usd]).to be < 2.0
    end
  end
end
