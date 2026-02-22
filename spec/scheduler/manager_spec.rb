# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe Homunculus::Scheduler::Manager do
  let(:config) do
    raw = TomlRB.load_file("config/default.toml")
    raw["scheduler"] = {
      "enabled" => true,
      "db_path" => db_path,
      "heartbeat" => {
        "enabled" => false,
        "cron" => "*/30 8-22 * * *",
        "model" => "local",
        "active_hours_start" => 8,
        "active_hours_end" => 22,
        "timezone" => "UTC"
      },
      "notification" => {
        "max_per_hour" => 10,
        "quiet_hours_queue" => true
      }
    }
    Homunculus::Config.new(raw)
  end

  let(:db_dir) { Dir.mktmpdir }
  let(:db_path) { File.join(db_dir, "test_scheduler.db") }
  let(:job_store) { Homunculus::Scheduler::JobStore.new(db_path:) }
  let(:delivered) { [] }
  let(:notification) do
    Homunculus::Scheduler::Notification.new(
      config:,
      deliver_fn: ->(text, priority) { delivered << { text:, priority: } }
    )
  end

  let(:agent_loop) { instance_double(Homunculus::Agent::Loop) }
  let(:manager) do
    described_class.new(
      config:,
      agent_loop:,
      notification:,
      job_store:
    )
  end

  after do
    manager.stop if manager.running?
    FileUtils.rm_rf(db_dir)
  end

  describe "#add_cron_job" do
    it "registers a cron job with rufus-scheduler" do
      manager.add_cron_job(
        name: "test_cron",
        cron: "0 9 * * *",
        agent_prompt: "Do something",
        notify: true
      )

      jobs = manager.list_jobs
      expect(jobs.size).to be >= 1 # At least our job + queue flush
      test_job = jobs.find { |j| j[:name] == "test_cron" }
      expect(test_job).not_to be_nil
      expect(test_job[:type]).to eq("cron")
    end

    it "persists the job in the store" do
      manager.add_cron_job(
        name: "persistent_cron",
        cron: "0 9 * * *",
        agent_prompt: "Morning check"
      )

      stored = job_store.all_jobs
      expect(stored.find { |j| j[:name] == "persistent_cron" }).not_to be_nil
    end
  end

  describe "#add_interval_job" do
    it "registers an interval job" do
      manager.add_interval_job(
        name: "test_interval",
        interval_minutes: 30,
        agent_prompt: "Check sensors"
      )

      jobs = manager.list_jobs
      test_job = jobs.find { |j| j[:name] == "test_interval" }
      expect(test_job).not_to be_nil
      expect(test_job[:type]).to eq("interval")
    end
  end

  describe "#remove_job" do
    it "removes a job from both scheduler and store" do
      manager.add_cron_job(
        name: "to_remove",
        cron: "0 9 * * *",
        agent_prompt: "x"
      )

      manager.remove_job("to_remove")

      expect(manager.list_jobs.find { |j| j[:name] == "to_remove" }).to be_nil
      expect(job_store.all_jobs.find { |j| j[:name] == "to_remove" }).to be_nil
    end
  end

  describe "#pause_job / #resume_job" do
    before do
      manager.add_cron_job(name: "pausable", cron: "0 9 * * *", agent_prompt: "x")
    end

    it "pauses a running job" do
      manager.pause_job("pausable")

      job = manager.list_jobs.find { |j| j[:name] == "pausable" }
      expect(job[:paused]).to be true
    end

    it "resumes a paused job" do
      manager.pause_job("pausable")
      manager.resume_job("pausable")

      job = manager.list_jobs.find { |j| j[:name] == "pausable" }
      expect(job[:paused]).to be false
    end
  end

  describe "job execution" do
    it "runs agent_loop and notifies on completion" do
      result = Homunculus::Agent::AgentResult.completed(
        "Sensors normal: temp=25°C, humidity=80%",
        session: Homunculus::Session.new
      )

      allow(agent_loop).to receive(:run).and_return(result)
      allow(notification).to receive(:quiet_hours?).and_return(false)

      # Use send to test private method directly
      manager.send(:execute_job, name: "test", agent_prompt: "Check sensors", notify: true)

      expect(agent_loop).to have_received(:run).with("Check sensors", kind_of(Homunculus::Session))
      expect(delivered.size).to eq(1)
      expect(delivered.first[:text]).to include("Sensors normal")
    end

    it "does not notify for HEARTBEAT_OK responses" do
      result = Homunculus::Agent::AgentResult.completed(
        "HEARTBEAT_OK - all systems nominal",
        session: Homunculus::Session.new
      )

      allow(agent_loop).to receive(:run).and_return(result)

      manager.send(:execute_job, name: "heartbeat", agent_prompt: "Check all", notify: true)

      expect(delivered).to be_empty
    end

    it "creates a session with source :scheduler" do
      captured_session = nil
      allow(agent_loop).to receive(:run) do |_prompt, session|
        captured_session = session
        Homunculus::Agent::AgentResult.completed("OK", session:)
      end

      manager.send(:execute_job, name: "test", agent_prompt: "Check", notify: false)

      expect(captured_session).not_to be_nil
      expect(captured_session.source).to eq(:scheduler)
    end

    it "records execution in the job store" do
      result = Homunculus::Agent::AgentResult.completed("Done", session: Homunculus::Session.new)
      allow(agent_loop).to receive(:run).and_return(result)

      manager.send(:execute_job, name: "recorded", agent_prompt: "Do it", notify: false)

      executions = job_store.recent_executions("recorded")
      expect(executions.size).to eq(1)
      expect(executions.first[:status]).to eq("completed")
    end

    it "records errors on agent failure" do
      result = Homunculus::Agent::AgentResult.error("Max turns exceeded", session: Homunculus::Session.new)
      allow(agent_loop).to receive(:run).and_return(result)

      manager.send(:execute_job, name: "failing", agent_prompt: "Fail", notify: false)

      executions = job_store.recent_executions("failing")
      expect(executions.first[:status]).to eq("error")
    end
  end

  describe "#start (restore persisted jobs)" do
    it "restores jobs from the store on start" do
      job_store.save_job(
        name: "restored_job",
        type: "cron",
        schedule: "0 9 * * *",
        agent_prompt: "Morning routine"
      )

      # Create a fresh manager that will restore
      fresh_manager = described_class.new(
        config:, agent_loop:, notification:, job_store:
      )
      fresh_manager.start

      jobs = fresh_manager.list_jobs
      expect(jobs.find { |j| j[:name] == "restored_job" }).not_to be_nil

      fresh_manager.stop
    end
  end

  describe "#status" do
    it "returns a status summary" do
      manager.start
      status = manager.status

      expect(status).to include(:running, :job_count, :persisted_count, :queue_size, :active_hours)
      expect(status[:running]).to be true
    end
  end
end
