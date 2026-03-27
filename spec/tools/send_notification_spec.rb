# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/homunculus/familiars/channel"
require_relative "../../lib/homunculus/familiars/registry"
require_relative "../../lib/homunculus/familiars/dispatcher"
require_relative "../../lib/homunculus/familiars/channels/log"
require_relative "../../lib/homunculus/tools/send_notification"

RSpec.describe Homunculus::Tools::SendNotification do
  subject(:tool) { described_class.new(familiars_dispatcher: dispatcher) }

  let(:registry)   { Homunculus::Familiars::Registry.new }
  let(:dispatcher) { Homunculus::Familiars::Dispatcher.new(registry:) }
  let(:log_channel) { Homunculus::Familiars::Channels::Log.new }
  let(:session) { instance_double(Homunculus::Session, id: "test-session") }

  before { registry.register(log_channel) }

  describe "metadata" do
    it "has tool name send_notification" do
      expect(tool.name).to eq("send_notification")
    end

    it "requires confirmation" do
      expect(tool.requires_confirmation).to be true
    end

    it "has :mixed trust level" do
      expect(tool.trust_level).to eq(:mixed)
    end

    it "has title and message as required parameters" do
      expect(tool.parameters[:title][:required]).to be true
      expect(tool.parameters[:message][:required]).to be true
    end

    it "has priority as optional parameter with enum" do
      expect(tool.parameters[:priority][:required]).to be false
      expect(tool.parameters[:priority][:enum]).to include("low", "normal", "high")
    end
  end

  describe "#execute" do
    context "with valid arguments" do
      it "delivers the notification and returns success" do
        result = tool.execute(
          arguments: { title: "Reminder", message: "Time to drink water!" },
          session:
        )

        expect(result.success).to be true
        expect(result.output).to include("Notification sent")
        expect(result.output).to include("Reminder")
      end

      it "delivers with :normal priority by default" do
        result = tool.execute(
          arguments: { title: "T", message: "M" },
          session:
        )

        expect(result.success).to be true
        expect(result.output).to include("priority: normal")
      end

      it "delivers with the specified priority" do
        result = tool.execute(
          arguments: { title: "Alert", message: "Urgent!", priority: "high" },
          session:
        )

        expect(result.success).to be true
        expect(result.output).to include("priority: high")
      end
    end

    context "with missing required parameters" do
      it "fails when title is missing" do
        result = tool.execute(
          arguments: { message: "No title" },
          session:
        )

        expect(result.success).to be false
        expect(result.error).to include("Missing required parameter: title")
      end

      it "fails when message is missing" do
        result = tool.execute(
          arguments: { title: "No message" },
          session:
        )

        expect(result.success).to be false
        expect(result.error).to include("Missing required parameter: message")
      end

      it "fails when title is blank" do
        result = tool.execute(
          arguments: { title: "  ", message: "Body" },
          session:
        )

        expect(result.success).to be false
        expect(result.error).to include("Missing required parameter: title")
      end
    end

    context "with invalid priority" do
      it "fails and explains valid values" do
        result = tool.execute(
          arguments: { title: "T", message: "M", priority: "ultra" },
          session:
        )

        expect(result.success).to be false
        expect(result.error).to include("Invalid priority")
      end
    end

    context "when Familiars is not initialized" do
      subject(:tool_no_dispatcher) { described_class.new(familiars_dispatcher: nil) }

      it "returns a descriptive failure" do
        result = tool_no_dispatcher.execute(
          arguments: { title: "T", message: "M" },
          session:
        )

        expect(result.success).to be false
        expect(result.error).to include("Familiars not enabled")
      end
    end

    context "when all channels fail" do
      subject(:tool_with_failing_channels) do
        described_class.new(familiars_dispatcher: failing_dispatcher)
      end

      let(:failing_channel) do
        ch = instance_double(Homunculus::Familiars::Channel)
        allow(ch).to receive(:is_a?).with(Homunculus::Familiars::Channel).and_return(true)
        allow(ch).to receive_messages(name: :failing, enabled?: true)
        allow(ch).to receive(:deliver).and_raise("Network error")
        ch
      end

      let(:failing_registry) { Homunculus::Familiars::Registry.new }
      let(:failing_dispatcher) { Homunculus::Familiars::Dispatcher.new(registry: failing_registry) }

      before { failing_registry.register(failing_channel) }

      it "returns failure when all channels fail" do
        result = tool_with_failing_channels.execute(
          arguments: { title: "T", message: "M" },
          session:
        )

        expect(result.success).to be false
        expect(result.error).to include("failed on all channels")
      end
    end
  end
end
