# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Scheduler::Notification do
  let(:config) do
    raw = TomlRB.load_file("config/default.toml")
    # Override scheduler settings for testing
    raw["scheduler"] = {
      "enabled" => true,
      "db_path" => "./data/test_scheduler.db",
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

  let(:delivered_messages) { [] }
  let(:deliver_fn) { ->(text, priority) { delivered_messages << { text:, priority: } } }
  let(:notification) { described_class.new(config:, deliver_fn:) }

  describe "#notify" do
    context "with low priority" do
      it "logs only, never delivers" do
        result = notification.notify("Low priority message", priority: :low)

        expect(result).to eq(:logged)
        expect(delivered_messages).to be_empty
      end
    end

    context "with normal priority during active hours" do
      before do
        allow(notification).to receive(:quiet_hours?).and_return(false)
      end

      it "delivers the message" do
        result = notification.notify("Normal message")

        expect(result).to eq(:delivered)
        expect(delivered_messages.size).to eq(1)
        expect(delivered_messages.first[:text]).to eq("Normal message")
        expect(delivered_messages.first[:priority]).to eq(:normal)
      end
    end

    context "with normal priority during quiet hours" do
      before do
        allow(notification).to receive(:quiet_hours?).and_return(true)
      end

      it "queues the message" do
        result = notification.notify("Queued message")

        expect(result).to eq(:queued)
        expect(delivered_messages).to be_empty
        expect(notification.queue_size).to eq(1)
      end
    end

    context "with high priority during quiet hours" do
      before do
        allow(notification).to receive(:quiet_hours?).and_return(true)
      end

      it "delivers immediately regardless of quiet hours" do
        result = notification.notify("Urgent alert!", priority: :high)

        expect(result).to eq(:delivered)
        expect(delivered_messages.size).to eq(1)
      end
    end
  end

  describe "#flush_queue" do
    before do
      allow(notification).to receive(:quiet_hours?).and_return(true)
    end

    it "delivers all queued notifications" do
      notification.notify("Message 1")
      notification.notify("Message 2")
      notification.notify("Message 3")

      expect(notification.queue_size).to eq(3)

      # Switch to active hours for flush
      allow(notification).to receive(:quiet_hours?).and_return(false)

      count = notification.flush_queue

      expect(count).to eq(3)
      expect(notification.queue_size).to eq(0)
      expect(delivered_messages.size).to eq(3)
    end

    it "returns 0 when queue is empty" do
      count = notification.flush_queue
      expect(count).to eq(0)
    end
  end

  describe "rate limiting" do
    before do
      allow(notification).to receive(:quiet_hours?).and_return(false)
    end

    it "rate limits after max_per_hour deliveries" do
      10.times { |i| notification.notify("Message #{i}") }

      expect(delivered_messages.size).to eq(10)

      # 11th should be rate limited
      result = notification.notify("One too many")
      expect(result).to eq(:rate_limited)
      expect(delivered_messages.size).to eq(10)
    end

    it "tracks deliveries in last hour" do
      3.times { notification.notify("msg") }
      expect(notification.deliveries_last_hour).to eq(3)
    end
  end

  describe "#quiet_hours?" do
    it "returns true before active hours start" do
      # Force time to 3 AM UTC
      allow(notification).to receive(:current_time_in_timezone)
        .and_return(Time.utc(2025, 1, 1, 3, 0))

      # Need to call the real method
      allow(notification).to receive(:quiet_hours?).and_call_original

      expect(notification.quiet_hours?).to be true
    end

    it "returns false during active hours" do
      allow(notification).to receive(:current_time_in_timezone)
        .and_return(Time.utc(2025, 1, 1, 12, 0))

      allow(notification).to receive(:quiet_hours?).and_call_original

      expect(notification.quiet_hours?).to be false
    end

    it "returns true after active hours end" do
      allow(notification).to receive(:current_time_in_timezone)
        .and_return(Time.utc(2025, 1, 1, 23, 0))

      allow(notification).to receive(:quiet_hours?).and_call_original

      expect(notification.quiet_hours?).to be true
    end
  end

  describe "delivery failure handling" do
    let(:failing_fn) { ->(_text, _priority) { raise "Network error" } }
    let(:notification) { described_class.new(config:, deliver_fn: failing_fn) }

    before do
      allow(notification).to receive(:quiet_hours?).and_return(false)
    end

    it "queues the message on delivery failure" do
      result = notification.notify("Will fail")

      expect(result).to eq(:queued)
      expect(notification.queue_size).to eq(1)
    end
  end

  describe "without deliver_fn" do
    let(:notification) { described_class.new(config:) }

    before do
      allow(notification).to receive(:quiet_hours?).and_return(false)
    end

    it "logs the notification when no delivery function is set" do
      result = notification.notify("No delivery fn")
      expect(result).to eq(:logged)
    end
  end
end
