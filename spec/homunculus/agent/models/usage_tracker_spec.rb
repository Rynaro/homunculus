# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Homunculus::Agent::Models::UsageTracker do
  let(:tmpdir) { Dir.mktmpdir("llm_usage_test") }
  let(:tracker) { described_class.new(storage_dir: tmpdir) }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def make_response(provider: :ollama, cost_usd: 0.0, tier: :workhorse, model: "test-model",
                    prompt_tokens: 100, completion_tokens: 50, latency_ms: 500)
    Homunculus::Agent::Models::Response.new(
      content: "Test response",
      tool_calls: [],
      model: model,
      provider: provider,
      tier: tier,
      usage: { prompt_tokens: prompt_tokens, completion_tokens: completion_tokens,
               total_tokens: prompt_tokens + completion_tokens },
      latency_ms: latency_ms,
      cost_usd: cost_usd,
      finish_reason: :stop,
      escalated_from: nil,
      metadata: {}
    )
  end

  describe "#record" do
    it "creates a JSONL file for today" do
      tracker.record(make_response)

      file = File.join(tmpdir, "#{Date.today.strftime("%Y-%m-%d")}.jsonl")
      expect(File.exist?(file)).to be true

      lines = File.readlines(file)
      expect(lines.size).to eq(1)

      record = JSON.parse(lines.first)
      expect(record["model"]).to eq("test-model")
      expect(record["provider"]).to eq("ollama")
      expect(record["tier"]).to eq("workhorse")
      expect(record["tokens_in"]).to eq(100)
      expect(record["tokens_out"]).to eq(50)
      expect(record["cost_usd"]).to eq(0.0)
    end

    it "appends multiple records to the same file" do
      tracker.record(make_response)
      tracker.record(make_response(model: "second-model"))

      file = File.join(tmpdir, "#{Date.today.strftime("%Y-%m-%d")}.jsonl")
      lines = File.readlines(file)
      expect(lines.size).to eq(2)
    end

    it "records escalation metadata" do
      escalated = Homunculus::Agent::Models::Response.new(
        content: "Cloud response",
        tool_calls: [],
        model: "claude-haiku-4-5-20251001",
        provider: :anthropic,
        tier: :cloud_fast,
        usage: { prompt_tokens: 200, completion_tokens: 100, total_tokens: 300 },
        latency_ms: 1200,
        cost_usd: 0.001,
        finish_reason: :stop,
        escalated_from: :workhorse,
        metadata: {}
      )

      tracker.record(escalated)

      file = File.join(tmpdir, "#{Date.today.strftime("%Y-%m-%d")}.jsonl")
      record = JSON.parse(File.readlines(file).first)
      expect(record["escalated_from"]).to eq("workhorse")
      expect(record["cost_usd"]).to eq(0.001)
    end

    it "records skill name when provided" do
      tracker.record(make_response, skill: "code_review")

      file = File.join(tmpdir, "#{Date.today.strftime("%Y-%m-%d")}.jsonl")
      record = JSON.parse(File.readlines(file).first)
      expect(record["skill"]).to eq("code_review")
    end
  end

  describe "#daily_summary" do
    it "returns empty summary for days with no data" do
      summary = tracker.daily_summary(Date.today)
      expect(summary[:total_calls]).to eq(0)
      expect(summary[:total_cost_usd]).to eq(0)
    end

    it "aggregates a day's records" do
      tracker.record(make_response(prompt_tokens: 100, completion_tokens: 50))
      tracker.record(make_response(prompt_tokens: 200, completion_tokens: 100, provider: :anthropic, cost_usd: 0.005))

      summary = tracker.daily_summary
      expect(summary[:total_calls]).to eq(2)
      expect(summary[:total_tokens_in]).to eq(300)
      expect(summary[:total_tokens_out]).to eq(150)
      expect(summary[:total_cost_usd]).to be_within(0.0001).of(0.005)
      expect(summary[:by_provider]).to eq({ "ollama" => 1, "anthropic" => 1 })
    end
  end

  describe "#monthly_cloud_spend_usd" do
    it "returns 0.0 when no cloud usage" do
      tracker.record(make_response(provider: :ollama, cost_usd: 0.0))

      expect(tracker.monthly_cloud_spend_usd).to eq(0.0)
    end

    it "sums only anthropic costs" do
      tracker.record(make_response(provider: :ollama, cost_usd: 0.0))
      tracker.record(make_response(provider: :anthropic, cost_usd: 0.01))
      tracker.record(make_response(provider: :anthropic, cost_usd: 0.02))

      expect(tracker.monthly_cloud_spend_usd).to be_within(0.001).of(0.03)
    end
  end

  describe "#model_stats" do
    it "returns per-model performance stats" do
      tracker.record(make_response(model: "model-a", latency_ms: 500, prompt_tokens: 100, completion_tokens: 50))
      tracker.record(make_response(model: "model-a", latency_ms: 700, prompt_tokens: 200, completion_tokens: 100))
      tracker.record(make_response(model: "model-b", latency_ms: 300, prompt_tokens: 50, completion_tokens: 25))

      stats = tracker.model_stats(period: :day)

      expect(stats["model-a"][:calls]).to eq(2)
      expect(stats["model-a"][:avg_latency_ms]).to eq(600)
      expect(stats["model-a"][:total_tokens]).to eq(450) # (100+50) + (200+100)
      expect(stats["model-b"][:calls]).to eq(1)
    end
  end

  describe "#budget_status" do
    it "reports budget status correctly" do
      tracker.record(make_response(provider: :anthropic, cost_usd: 15.0))

      status = tracker.budget_status(monthly_limit: 30.0)
      expect(status[:spent]).to eq(15.0)
      expect(status[:limit]).to eq(30.0)
      expect(status[:remaining]).to eq(15.0)
      expect(status[:percent]).to eq(50.0)
    end

    it "reports 0% when no spending" do
      status = tracker.budget_status(monthly_limit: 30.0)
      expect(status[:percent]).to eq(0.0)
      expect(status[:remaining]).to eq(30.0)
    end
  end

  describe "#monthly_summary" do
    it "aggregates across the current month" do
      tracker.record(make_response)
      tracker.record(make_response(provider: :anthropic, cost_usd: 0.01))

      summary = tracker.monthly_summary
      expect(summary[:total_calls]).to eq(2)
      expect(summary[:escalations]).to eq(0)
    end
  end
end
