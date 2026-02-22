# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe Homunculus::Scheduler::JobStore do
  let(:db_dir) { Dir.mktmpdir }
  let(:db_path) { File.join(db_dir, "test_scheduler.db") }
  let(:store) { described_class.new(db_path:) }

  after do
    FileUtils.rm_rf(db_dir)
  end

  describe "#save_job" do
    it "persists a new cron job" do
      store.save_job(
        name: "morning_check",
        type: "cron",
        schedule: "0 9 * * *",
        agent_prompt: "Check morning status",
        notify: true
      )

      expect(store.count).to eq(1)
      jobs = store.all_jobs
      expect(jobs.first[:name]).to eq("morning_check")
      expect(jobs.first[:type]).to eq("cron")
      expect(jobs.first[:schedule]).to eq("0 9 * * *")
      expect(jobs.first[:notify]).to be true
    end

    it "updates an existing job with the same name" do
      store.save_job(name: "test", type: "cron", schedule: "0 9 * * *", agent_prompt: "v1")
      store.save_job(name: "test", type: "cron", schedule: "0 10 * * *", agent_prompt: "v2")

      expect(store.count).to eq(1)
      expect(store.all_jobs.first[:schedule]).to eq("0 10 * * *")
      expect(store.all_jobs.first[:agent_prompt]).to eq("v2")
    end

    it "stores metadata as JSON" do
      store.save_job(
        name: "meta_job",
        type: "interval",
        schedule: "30m",
        agent_prompt: "check",
        metadata: { source: "heartbeat", priority: "high" }
      )

      job = store.all_jobs.first
      expect(job[:metadata]).to eq({ "source" => "heartbeat", "priority" => "high" })
    end
  end

  describe "#remove_job" do
    it "deletes a job by name" do
      store.save_job(name: "to_remove", type: "cron", schedule: "* * * * *", agent_prompt: "x")
      expect(store.count).to eq(1)

      result = store.remove_job("to_remove")
      expect(result).to be true
      expect(store.count).to eq(0)
    end

    it "returns false for non-existent job" do
      result = store.remove_job("nonexistent")
      expect(result).to be false
    end
  end

  describe "#pause_job / #resume_job" do
    before do
      store.save_job(name: "pausable", type: "cron", schedule: "* * * * *", agent_prompt: "x")
    end

    it "marks a job as paused" do
      store.pause_job("pausable")
      expect(store.all_jobs.first[:paused]).to be true
    end

    it "marks a job as resumed" do
      store.pause_job("pausable")
      store.resume_job("pausable")
      expect(store.all_jobs.first[:paused]).to be false
    end
  end

  describe "#record_execution" do
    it "records an execution entry" do
      store.save_job(name: "exec_test", type: "cron", schedule: "* * * * *", agent_prompt: "x")

      store.record_execution(name: "exec_test", status: "completed", duration_ms: 1500,
                             result_summary: "All good")

      executions = store.recent_executions("exec_test")
      expect(executions.size).to eq(1)
      expect(executions.first[:status]).to eq("completed")
      expect(executions.first[:duration_ms]).to eq(1500)
    end

    it "returns recent executions in reverse chronological order" do
      3.times do |i|
        store.record_execution(name: "order_test", status: "run_#{i}", duration_ms: i * 100)
      end

      executions = store.recent_executions("order_test", limit: 3)
      expect(executions.map { |e| e[:status] }).to eq(%w[run_2 run_1 run_0])
    end
  end

  describe "persistence across restarts" do
    it "survives re-initialization with the same db_path" do
      store.save_job(name: "persistent", type: "cron", schedule: "0 8 * * *",
                     agent_prompt: "Wake up check")
      store.record_execution(name: "persistent", status: "completed", duration_ms: 500)

      # Simulate restart: create a new store pointing to same DB
      new_store = described_class.new(db_path:)

      expect(new_store.count).to eq(1)
      expect(new_store.all_jobs.first[:name]).to eq("persistent")
      expect(new_store.recent_executions("persistent").size).to eq(1)
    end
  end
end
