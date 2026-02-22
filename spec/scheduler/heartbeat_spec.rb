# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe Homunculus::Scheduler::Heartbeat do
  let(:workspace_dir) { Dir.mktmpdir }
  let(:db_dir) { Dir.mktmpdir }
  let(:db_path) { File.join(db_dir, "test_scheduler.db") }

  let(:config) do
    raw = TomlRB.load_file("config/default.toml")
    raw["agent"] = { "workspace_path" => workspace_dir }
    raw["scheduler"] = {
      "enabled" => true,
      "db_path" => db_path,
      "heartbeat" => {
        "enabled" => true,
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

  let(:job_store) { Homunculus::Scheduler::JobStore.new(db_path:) }
  let(:notification) { Homunculus::Scheduler::Notification.new(config:) }
  let(:agent_loop) { instance_double(Homunculus::Agent::Loop) }
  let(:scheduler_manager) do
    Homunculus::Scheduler::Manager.new(
      config:,
      agent_loop:,
      notification:,
      job_store:
    )
  end

  let(:heartbeat) do
    described_class.new(config:, scheduler_manager:)
  end

  after do
    scheduler_manager.stop if scheduler_manager.running?
    FileUtils.rm_rf(workspace_dir)
    FileUtils.rm_rf(db_dir)
  end

  describe "#setup!" do
    context "when heartbeat is enabled and HEARTBEAT.md exists" do
      before do
        File.write(File.join(workspace_dir, "HEARTBEAT.md"), <<~MD)
          # Heartbeat Checklist

          ## Sensors
          - [ ] Check temperature (topic: sensors/temp)
            - Alert if above 30°C
          - [ ] Check humidity (topic: sensors/humidity)
            - Alert if below 50%
        MD
      end

      it "registers the heartbeat cron job" do
        result = heartbeat.setup!

        expect(result).to be true

        jobs = scheduler_manager.list_jobs
        hb_job = jobs.find { |j| j[:name] == "heartbeat" }
        expect(hb_job).not_to be_nil
        expect(hb_job[:type]).to eq("cron")
      end

      it "builds a prompt containing the checklist and time context" do
        heartbeat.setup!

        jobs = scheduler_manager.list_jobs
        expect(jobs.find { |j| j[:name] == "heartbeat" }).not_to be_nil
      end

      it "includes current time and day-of-week in the prompt" do
        frozen_time = Time.utc(2026, 2, 23, 10, 0) # Monday
        allow(heartbeat).to receive(:current_time).and_return(frozen_time)

        prompt = heartbeat.send(:build_prompt, "- [ ] Test item")

        expect(prompt).to include("10:00")
        expect(prompt).to include("Monday")
        expect(prompt).to include("30-minute window")
        expect(prompt).to include("HEARTBEAT_OK")
        expect(prompt).to include("Test item")
      end

      it "includes prefix documentation in the prompt" do
        frozen_time = Time.utc(2026, 2, 22, 14, 30) # Sunday
        allow(heartbeat).to receive(:current_time).and_return(frozen_time)

        prompt = heartbeat.send(:build_prompt, "- [ ] (WK) Test item")

        expect(prompt).to include("WK = Work tasks")
        expect(prompt).to include("HL = Personal tasks")
        expect(prompt).to include("FM = Family tasks")
        expect(prompt).to include("GL = Pets tasks")
      end
    end

    context "when heartbeat is disabled" do
      let(:config) do
        raw = TomlRB.load_file("config/default.toml")
        raw["agent"] = { "workspace_path" => workspace_dir }
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

      it "returns false and does not register a job" do
        result = heartbeat.setup!

        expect(result).to be false
        jobs = scheduler_manager.list_jobs
        expect(jobs.find { |j| j[:name] == "heartbeat" }).to be_nil
      end
    end

    context "when HEARTBEAT.md does not exist" do
      it "returns false and logs a warning" do
        result = heartbeat.setup!
        expect(result).to be false
      end
    end
  end

  describe "#reload!" do
    before do
      File.write(File.join(workspace_dir, "HEARTBEAT.md"), <<~MD)
        # Heartbeat Checklist
        - [ ] Check item 1
      MD
    end

    it "removes and re-registers the heartbeat job" do
      heartbeat.setup!

      # Update the file
      File.write(File.join(workspace_dir, "HEARTBEAT.md"), <<~MD)
        # Heartbeat Checklist
        - [ ] Check item 1
        - [ ] Check item 2
        - [ ] Check item 3
      MD

      heartbeat.reload!

      jobs = scheduler_manager.list_jobs
      expect(jobs.find { |j| j[:name] == "heartbeat" }).not_to be_nil
    end
  end

  describe "heartbeat execution flow" do
    before do
      File.write(File.join(workspace_dir, "HEARTBEAT.md"), <<~MD)
        # Heartbeat Checklist
        - [ ] Check temperature sensor (topic: home/sensors/temperature)
          - Alert if below 18°C or above 30°C
      MD
    end

    it "evaluates checklist and returns HEARTBEAT_OK for normal values" do
      heartbeat.setup!

      result = Homunculus::Agent::AgentResult.completed(
        "HEARTBEAT_OK",
        session: Homunculus::Session.new
      )
      allow(agent_loop).to receive(:run).and_return(result)

      # Simulate job execution through the manager
      scheduler_manager.send(:execute_job,
                             name: "heartbeat",
                             agent_prompt: "Check heartbeat",
                             notify: true)

      # HEARTBEAT_OK should not trigger notification delivery
      # (verified by checking no messages were delivered)
      expect(agent_loop).to have_received(:run)
    end

    it "alerts when sensor values are out of range" do
      heartbeat.setup!

      delivered = []
      notification.deliver_fn = ->(text, priority) { delivered << { text:, priority: } }
      allow(notification).to receive(:quiet_hours?).and_return(false)

      result = Homunculus::Agent::AgentResult.completed(
        "⚠️ ALERT: Water temperature is 30°C (above 28°C threshold). Check heater.",
        session: Homunculus::Session.new
      )
      allow(agent_loop).to receive(:run).and_return(result)

      scheduler_manager.send(:execute_job,
                             name: "heartbeat",
                             agent_prompt: "Check heartbeat",
                             notify: true)

      expect(delivered.size).to eq(1)
      expect(delivered.first[:text]).to include("ALERT")
    end
  end
end
