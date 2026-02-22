# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Tools::SchedulerManage do
  subject(:tool) { described_class.new(scheduler_manager: manager) }

  let(:session) { Homunculus::Session.new }
  let(:manager) { instance_double(Homunculus::Scheduler::Manager) }

  describe "metadata" do
    it "has correct tool name" do
      expect(tool.name).to eq("scheduler_manage")
    end

    it "requires confirmation" do
      expect(tool.requires_confirmation).to be true
    end

    it "has untrusted trust level" do
      expect(tool.trust_level).to eq(:untrusted)
    end

    it "defines the action parameter with enum" do
      params = tool.json_schema_parameters
      expect(params[:properties]["action"][:enum]).to eq(
        %w[add_reminder add_cron add_interval list status remove pause resume history]
      )
      expect(params[:required]).to include("action")
    end

    it "defines optional parameters" do
      params = tool.json_schema_parameters
      expect(params[:properties]).to have_key("name")
      expect(params[:properties]).to have_key("delay")
      expect(params[:properties]).to have_key("cron")
      expect(params[:properties]).to have_key("interval_minutes")
      expect(params[:properties]).to have_key("agent_prompt")
      expect(params[:properties]).to have_key("notify")
      expect(params[:required]).to eq(["action"])
    end
  end

  describe "missing action" do
    it "fails when action is missing" do
      result = tool.execute(arguments: {}, session:)

      expect(result.success).to be false
      expect(result.error).to include("Missing required parameter: action")
    end

    it "fails for unknown action" do
      result = tool.execute(arguments: { action: "explode" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Unknown action: explode")
    end
  end

  describe "add_reminder" do
    it "creates a one-shot job" do
      allow(manager).to receive(:add_one_shot_job)

      result = tool.execute(
        arguments: { action: "add_reminder", name: "test_reminder", delay: "2m", agent_prompt: "Say hello" },
        session:
      )

      expect(result.success).to be true
      expect(result.output).to include("test_reminder")
      expect(manager).to have_received(:add_one_shot_job).with(
        name: "test_reminder", delay: "2m", agent_prompt: "Say hello", notify: true
      )
    end

    it "passes notify: false when specified" do
      allow(manager).to receive(:add_one_shot_job)

      tool.execute(
        arguments: { action: "add_reminder", name: "quiet", delay: "5m", agent_prompt: "Shh", notify: false },
        session:
      )

      expect(manager).to have_received(:add_one_shot_job).with(
        name: "quiet", delay: "5m", agent_prompt: "Shh", notify: false
      )
    end

    it "fails without name" do
      result = tool.execute(arguments: { action: "add_reminder", delay: "2m", agent_prompt: "Hi" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("name")
    end

    it "fails without delay" do
      result = tool.execute(arguments: { action: "add_reminder", name: "x", agent_prompt: "Hi" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("delay")
    end

    it "fails without agent_prompt" do
      result = tool.execute(arguments: { action: "add_reminder", name: "x", delay: "2m" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("agent_prompt")
    end

    describe "delay validation" do
      it "accepts '2m'" do
        allow(manager).to receive(:add_one_shot_job)
        result = tool.execute(
          arguments: { action: "add_reminder", name: "x", delay: "2m", agent_prompt: "Go" }, session:
        )
        expect(result.success).to be true
      end

      it "accepts '1h30m'" do
        allow(manager).to receive(:add_one_shot_job)
        result = tool.execute(
          arguments: { action: "add_reminder", name: "x", delay: "1h30m", agent_prompt: "Go" }, session:
        )
        expect(result.success).to be true
      end

      it "accepts '5s'" do
        allow(manager).to receive(:add_one_shot_job)
        result = tool.execute(
          arguments: { action: "add_reminder", name: "x", delay: "5s", agent_prompt: "Go" }, session:
        )
        expect(result.success).to be true
      end

      it "accepts '2d'" do
        allow(manager).to receive(:add_one_shot_job)
        result = tool.execute(
          arguments: { action: "add_reminder", name: "x", delay: "2d", agent_prompt: "Go" }, session:
        )
        expect(result.success).to be true
      end

      it "rejects invalid format" do
        result = tool.execute(
          arguments: { action: "add_reminder", name: "x", delay: "soon", agent_prompt: "Go" }, session:
        )
        expect(result.success).to be false
        expect(result.error).to include("Invalid delay format")
      end

      it "rejects empty delay" do
        result = tool.execute(
          arguments: { action: "add_reminder", name: "x", delay: "", agent_prompt: "Go" }, session:
        )
        expect(result.success).to be false
        expect(result.error).to include("Invalid delay format")
      end
    end
  end

  describe "add_cron" do
    it "creates a cron job" do
      allow(manager).to receive(:add_cron_job)

      result = tool.execute(
        arguments: { action: "add_cron", name: "morning", cron: "0 9 * * 1-5", agent_prompt: "Good morning" },
        session:
      )

      expect(result.success).to be true
      expect(result.output).to include("morning")
      expect(manager).to have_received(:add_cron_job).with(
        name: "morning", cron: "0 9 * * 1-5", agent_prompt: "Good morning", notify: true
      )
    end

    it "fails without name" do
      result = tool.execute(arguments: { action: "add_cron", cron: "* * * * *", agent_prompt: "Hi" }, session:)
      expect(result.success).to be false
      expect(result.error).to include("name")
    end

    it "fails without cron" do
      result = tool.execute(arguments: { action: "add_cron", name: "x", agent_prompt: "Hi" }, session:)
      expect(result.success).to be false
      expect(result.error).to include("cron")
    end

    it "fails without agent_prompt" do
      result = tool.execute(arguments: { action: "add_cron", name: "x", cron: "* * * * *" }, session:)
      expect(result.success).to be false
      expect(result.error).to include("agent_prompt")
    end
  end

  describe "add_interval" do
    it "creates an interval job" do
      allow(manager).to receive(:add_interval_job)

      result = tool.execute(
        arguments: { action: "add_interval", name: "poller", interval_minutes: 15, agent_prompt: "Check sensors" },
        session:
      )

      expect(result.success).to be true
      expect(result.output).to include("poller")
      expect(manager).to have_received(:add_interval_job).with(
        name: "poller", interval_minutes: 15, agent_prompt: "Check sensors", notify: true
      )
    end

    it "fails without interval_minutes" do
      result = tool.execute(
        arguments: { action: "add_interval", name: "x", agent_prompt: "Hi" }, session:
      )
      expect(result.success).to be false
      expect(result.error).to include("interval_minutes")
    end
  end

  describe "list" do
    it "returns job list" do
      allow(manager).to receive(:list_jobs).and_return([
                                                         { name: "heartbeat", type: "cron", next_time: "2026-02-22 10:00",
                                                           paused: false },
                                                         { name: "poller", type: "interval", next_time: "2026-02-22 09:15",
                                                           paused: true }
                                                       ])

      result = tool.execute(arguments: { action: "list" }, session:)

      expect(result.success).to be true
      expect(result.output).to include("heartbeat")
      expect(result.output).to include("poller")
      expect(result.output).to include("paused")
    end

    it "reports no jobs" do
      allow(manager).to receive(:list_jobs).and_return([])

      result = tool.execute(arguments: { action: "list" }, session:)

      expect(result.success).to be true
      expect(result.output).to include("No scheduled jobs")
    end
  end

  describe "status" do
    it "returns scheduler status" do
      allow(manager).to receive(:status).and_return(
        running: true, job_count: 3, persisted_count: 2, queue_size: 0, active_hours: true
      )

      result = tool.execute(arguments: { action: "status" }, session:)

      expect(result.success).to be true
      expect(result.output).to include("Running: true")
      expect(result.output).to include("Jobs: 3")
    end
  end

  describe "remove" do
    it "removes a job" do
      allow(manager).to receive(:remove_job)

      result = tool.execute(arguments: { action: "remove", name: "old_job" }, session:)

      expect(result.success).to be true
      expect(manager).to have_received(:remove_job).with("old_job")
    end

    it "fails without name" do
      result = tool.execute(arguments: { action: "remove" }, session:)
      expect(result.success).to be false
      expect(result.error).to include("name")
    end
  end

  describe "pause" do
    it "pauses a job" do
      allow(manager).to receive(:pause_job)

      result = tool.execute(arguments: { action: "pause", name: "heartbeat" }, session:)

      expect(result.success).to be true
      expect(manager).to have_received(:pause_job).with("heartbeat")
    end

    it "fails without name" do
      result = tool.execute(arguments: { action: "pause" }, session:)
      expect(result.success).to be false
    end
  end

  describe "resume" do
    it "resumes a job" do
      allow(manager).to receive(:resume_job)

      result = tool.execute(arguments: { action: "resume", name: "heartbeat" }, session:)

      expect(result.success).to be true
      expect(manager).to have_received(:resume_job).with("heartbeat")
    end

    it "fails without name" do
      result = tool.execute(arguments: { action: "resume" }, session:)
      expect(result.success).to be false
    end
  end

  describe "history" do
    it "returns execution history" do
      executions = [
        { executed_at: Time.new(2026, 2, 22, 9, 0), status: "completed", duration_ms: 150, result_summary: "OK" },
        { executed_at: Time.new(2026, 2, 22, 9, 30), status: "error", duration_ms: 5000, result_summary: "Timeout" }
      ]
      allow(manager).to receive(:recent_executions).with("heartbeat").and_return(executions)

      result = tool.execute(arguments: { action: "history", name: "heartbeat" }, session:)

      expect(result.success).to be true
      expect(result.output).to include("completed")
      expect(result.output).to include("error")
    end

    it "reports no history" do
      allow(manager).to receive(:recent_executions).with("none").and_return([])

      result = tool.execute(arguments: { action: "history", name: "none" }, session:)

      expect(result.success).to be true
      expect(result.output).to include("No execution history")
    end

    it "fails without name" do
      result = tool.execute(arguments: { action: "history" }, session:)
      expect(result.success).to be false
    end
  end

  describe "error handling" do
    it "wraps manager exceptions in Result.fail" do
      allow(manager).to receive(:list_jobs).and_raise(RuntimeError, "scheduler crashed")

      result = tool.execute(arguments: { action: "list" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("scheduler crashed")
    end
  end
end
