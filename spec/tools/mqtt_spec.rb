# frozen_string_literal: true

require "spec_helper"

RSpec.describe "MQTT tools" do
  let(:session) { Homunculus::Session.new }
  let(:config) do
    raw = {
      "gateway" => { "host" => "127.0.0.1" },
      "models" => {
        "local" => {
          "provider" => "ollama", "context_window" => 32_768, "temperature" => 0.7
        }
      },
      "agent" => {},
      "tools" => {
        "sandbox" => {},
        "mqtt" => {
          "broker_host" => "localhost",
          "broker_port" => 1883,
          "username" => "",
          "password" => "",
          "client_id" => "homunculus-test",
          "allowed_topics" => ["home/#", "paludarium/#", "sensors/#"],
          "blocked_topics" => ["home/security/#", "home/locks/#"]
        }
      },
      "memory" => {},
      "security" => {}
    }
    Homunculus::Config.new(raw)
  end

  describe Homunculus::Tools::MQTTPublish do
    subject(:tool) { described_class.new(config:) }

    it "has correct metadata" do
      expect(tool.name).to eq("mqtt_publish")
      expect(tool.requires_confirmation).to be true
      expect(tool.trust_level).to eq(:untrusted)
    end

    it "fails when topic is missing" do
      result = tool.execute(arguments: { payload: "test" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Missing required parameter: topic")
    end

    it "fails when payload is missing" do
      result = tool.execute(arguments: { topic: "home/living_room/light/set" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Missing required parameter: payload")
    end

    describe "topic validation" do
      it "allows publishing to an allowed topic" do
        mqtt_client = instance_double(MQTT::Client)
        allow(MQTT::Client).to receive(:new).and_return(mqtt_client)
        allow(mqtt_client).to receive(:connect)
        allow(mqtt_client).to receive(:publish)
        allow(mqtt_client).to receive(:disconnect)

        result = tool.execute(
          arguments: { topic: "home/living_room/light/set", payload: '{"state":"ON"}' },
          session:
        )

        expect(result.success).to be true
        expect(result.output).to include("Published to home/living_room/light/set")
      end

      it "allows publishing to paludarium topic" do
        mqtt_client = instance_double(MQTT::Client)
        allow(MQTT::Client).to receive(:new).and_return(mqtt_client)
        allow(mqtt_client).to receive(:connect)
        allow(mqtt_client).to receive(:publish)
        allow(mqtt_client).to receive(:disconnect)

        result = tool.execute(
          arguments: { topic: "paludarium/misting/trigger", payload: "on" },
          session:
        )

        expect(result.success).to be true
      end

      it "rejects publishing to blocked security topic" do
        result = tool.execute(
          arguments: { topic: "home/security/alarm/disarm", payload: "1" },
          session:
        )

        expect(result.success).to be false
        expect(result.error).to include("Blocked topic")
      end

      it "rejects publishing to blocked locks topic" do
        result = tool.execute(
          arguments: { topic: "home/locks/front_door/unlock", payload: "1" },
          session:
        )

        expect(result.success).to be false
        expect(result.error).to include("Blocked topic")
      end

      it "rejects publishing to a topic not in allowed list" do
        result = tool.execute(
          arguments: { topic: "office/printer/status", payload: "test" },
          session:
        )

        expect(result.success).to be false
        expect(result.error).to include("Topic not allowed")
      end
    end

    describe "publish options" do
      it "passes retain flag" do
        mqtt_client = instance_double(MQTT::Client)
        allow(MQTT::Client).to receive(:new).and_return(mqtt_client)
        allow(mqtt_client).to receive(:connect)
        allow(mqtt_client).to receive(:disconnect)

        expect(mqtt_client).to receive(:publish).with(
          "home/living_room/temp/set", "22.5", retain: true, qos: 1
        )

        tool.execute(
          arguments: { topic: "home/living_room/temp/set", payload: "22.5", retain: true },
          session:
        )
      end

      it "clamps QoS to valid range" do
        mqtt_client = instance_double(MQTT::Client)
        allow(MQTT::Client).to receive(:new).and_return(mqtt_client)
        allow(mqtt_client).to receive(:connect)
        allow(mqtt_client).to receive(:disconnect)

        expect(mqtt_client).to receive(:publish).with(
          "home/living_room/temp/set", "22.5", retain: false, qos: 2
        )

        tool.execute(
          arguments: { topic: "home/living_room/temp/set", payload: "22.5", qos: 99 },
          session:
        )
      end
    end
  end

  describe Homunculus::Tools::MQTTSubscribe do
    subject(:tool) { described_class.new(config:) }

    it "has correct metadata" do
      expect(tool.name).to eq("mqtt_subscribe")
      expect(tool.requires_confirmation).to be false
      expect(tool.trust_level).to eq(:trusted)
    end

    it "fails when topic is missing" do
      result = tool.execute(arguments: {}, session:)

      expect(result.success).to be false
      expect(result.error).to include("Missing required parameter: topic")
    end

    describe "topic validation" do
      it "rejects subscribing to blocked topics" do
        result = tool.execute(arguments: { topic: "home/security/cameras/feed" }, session:)

        expect(result.success).to be false
        expect(result.error).to include("Blocked topic")
      end

      it "rejects subscribing to topics not in allowed list" do
        result = tool.execute(arguments: { topic: "office/printer/status" }, session:)

        expect(result.success).to be false
        expect(result.error).to include("Topic not allowed")
      end
    end

    describe "message collection" do
      it "collects messages within timeout" do
        mqtt_client = instance_double(MQTT::Client)
        allow(MQTT::Client).to receive(:new).and_return(mqtt_client)
        allow(mqtt_client).to receive(:connect)
        allow(mqtt_client).to receive(:subscribe)
        allow(mqtt_client).to receive(:disconnect)

        call_count = 0
        allow(mqtt_client).to receive(:get) do
          call_count += 1
          raise Timeout::Error unless call_count <= 2

          ["sensors/temperature/living_room", "22.#{call_count}"]
        end

        result = tool.execute(
          arguments: { topic: "sensors/temperature/living_room", count: 5, timeout: 2 },
          session:
        )

        expect(result.success).to be true
        expect(result.output).to include("sensors/temperature/living_room")
        expect(result.output).to include("22.1")
        expect(result.output).to include("22.2")
        expect(result.metadata[:count]).to eq(2)
      end

      it "returns message when no messages received" do
        mqtt_client = instance_double(MQTT::Client)
        allow(MQTT::Client).to receive(:new).and_return(mqtt_client)
        allow(mqtt_client).to receive(:connect)
        allow(mqtt_client).to receive(:subscribe)
        allow(mqtt_client).to receive(:disconnect)
        allow(mqtt_client).to receive(:get).and_raise(Timeout::Error)

        result = tool.execute(
          arguments: { topic: "sensors/empty", timeout: 1 },
          session:
        )

        expect(result.success).to be true
        expect(result.output).to include("No messages received")
      end
    end
  end

  describe "MQTT topic matching" do
    # Test the matching logic via the publish tool's validation
    subject(:tool) { Homunculus::Tools::MQTTPublish.new(config:) }

    it "matches single-level wildcard +" do
      raw = {
        "gateway" => { "host" => "127.0.0.1" },
        "models" => {
          "local" => { "provider" => "ollama", "context_window" => 32_768, "temperature" => 0.7 }
        },
        "tools" => {
          "sandbox" => {},
          "mqtt" => {
            "allowed_topics" => ["home/+/light/set"],
            "blocked_topics" => []
          }
        },
        "memory" => {},
        "security" => {}
      }
      config_with_plus = Homunculus::Config.new(raw)

      tool_with_plus = Homunculus::Tools::MQTTPublish.new(config: config_with_plus)
      mqtt_client = instance_double(MQTT::Client)
      allow(MQTT::Client).to receive(:new).and_return(mqtt_client)
      allow(mqtt_client).to receive_messages(connect: nil, publish: nil, disconnect: nil)

      result = tool_with_plus.execute(
        arguments: { topic: "home/bedroom/light/set", payload: "on" },
        session:
      )

      expect(result.success).to be true
    end

    it "matches multi-level wildcard #" do
      # home/# should match home/living_room/light/set
      mqtt_client = instance_double(MQTT::Client)
      allow(MQTT::Client).to receive(:new).and_return(mqtt_client)
      allow(mqtt_client).to receive_messages(connect: nil, publish: nil, disconnect: nil)

      result = tool.execute(
        arguments: { topic: "home/living_room/light/brightness/set", payload: "80" },
        session:
      )

      expect(result.success).to be true
    end
  end
end
