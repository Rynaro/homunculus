# frozen_string_literal: true

require "securerandom"
require "mqtt"

module Homunculus
  module Tools
    class MQTTPublish < Base
      tool_name "mqtt_publish"
      description <<~DESC.strip
        Publish a message to an MQTT topic on the home network.
        Use for: controlling devices, triggering automations, updating sensor displays.
        Topics follow pattern: home/{area}/{device}/{property}
      DESC
      trust_level :untrusted
      requires_confirmation true

      parameter :topic, type: :string, description: "MQTT topic to publish to (e.g. home/living_room/light/set)"
      parameter :payload, type: :string, description: "Message payload (typically JSON or simple value)"
      parameter :retain, type: :boolean, description: "Retain message on broker (default: false)", required: false
      parameter :qos, type: :integer, description: "Quality of Service level 0-2 (default: 1)", required: false

      def initialize(config:)
        super()
        @config = config
      end

      def execute(arguments:, session:)
        topic = arguments[:topic]
        payload = arguments[:payload]

        return Result.fail("Missing required parameter: topic") unless topic
        return Result.fail("Missing required parameter: payload") unless payload

        # Validate topic against allowed/blocked lists
        topic_check = validate_topic(topic)
        return Result.fail(topic_check) if topic_check

        retain = arguments.fetch(:retain, false)
        qos = arguments.fetch(:qos, 1).to_i.clamp(0, 2)

        mqtt_config = @config.mqtt

        client = build_client(mqtt_config)
        client.connect
        client.publish(topic, payload, retain:, qos:)
        client.disconnect

        Result.ok(
          "Published to #{topic} (#{payload.bytesize} bytes, qos=#{qos}, retain=#{retain})",
          topic:, payload_size: payload.bytesize, qos:, retain:
        )
      rescue StandardError => e
        Result.fail("MQTT publish error: #{e.message}")
      end

      private

      def validate_topic(topic)
        mqtt_config = @config.mqtt

        # Check blocked topics first (higher priority)
        blocked = mqtt_config.blocked_topics
        return "Blocked topic: #{topic} matches a blocked pattern" if topic_matches_any?(topic, blocked)

        # Check allowed topics
        allowed = mqtt_config.allowed_topics
        unless allowed.empty? || topic_matches_any?(topic, allowed)
          return "Topic not allowed: #{topic} does not match any allowed pattern"
        end

        nil
      end

      def topic_matches_any?(topic, patterns)
        patterns.any? { |pattern| mqtt_topic_match?(pattern, topic) }
      end

      # MQTT topic matching with wildcard support:
      # '#' matches any number of levels (must be last character)
      # '+' matches exactly one level
      def mqtt_topic_match?(pattern, topic)
        pattern_parts = pattern.split("/")
        topic_parts = topic.split("/")

        pattern_parts.each_with_index do |part, i|
          case part
          when "#"
            return true # Multi-level wildcard matches everything remaining
          when "+"
            return false if i >= topic_parts.size # No corresponding level
          else
            return false if i >= topic_parts.size || topic_parts[i] != part
          end
        end

        # Pattern consumed: topic must also be fully consumed
        pattern_parts.size == topic_parts.size
      end

      def build_client(mqtt_config)
        MQTT::Client.new(
          host: mqtt_config.broker_host,
          port: mqtt_config.broker_port,
          username: mqtt_config.username.empty? ? nil : mqtt_config.username,
          password: mqtt_config.password.empty? ? nil : mqtt_config.password,
          client_id: mqtt_config.client_id
        )
      end
    end

    class MQTTSubscribe < Base
      tool_name "mqtt_subscribe"
      description <<~DESC.strip
        Subscribe to an MQTT topic and read recent messages.
        Use for: checking sensor values, monitoring device status.
        Returns the last N messages received on the topic within a timeout window.
      DESC
      trust_level :trusted
      requires_confirmation false

      parameter :topic, type: :string, description: "MQTT topic to subscribe to (supports + and # wildcards)"
      parameter :count, type: :integer, description: "Max number of messages to collect (default: 5)", required: false
      parameter :timeout, type: :integer, description: "Seconds to wait for messages (default: 10, max: 30)",
                          required: false

      MAX_TIMEOUT = 30
      DEFAULT_TIMEOUT = 10
      DEFAULT_COUNT = 5

      def initialize(config:)
        super()
        @config = config
      end

      def execute(arguments:, session:)
        topic = arguments[:topic]
        return Result.fail("Missing required parameter: topic") unless topic

        # Validate topic against allowed/blocked lists (reuse same logic)
        topic_check = validate_topic(topic)
        return Result.fail(topic_check) if topic_check

        count = arguments.fetch(:count, DEFAULT_COUNT).to_i.clamp(1, 50)
        timeout = [arguments.fetch(:timeout, DEFAULT_TIMEOUT).to_i, MAX_TIMEOUT].min
        timeout = DEFAULT_TIMEOUT if timeout <= 0

        mqtt_config = @config.mqtt
        messages = collect_messages(mqtt_config, topic:, count:, timeout:)

        if messages.empty?
          Result.ok("No messages received on #{topic} within #{timeout}s",
                    topic:, count: 0, timeout:)
        else
          formatted = messages.map.with_index(1) do |msg, i|
            "[#{i}] #{msg[:topic]}: #{msg[:payload]}"
          end.join("\n")

          Result.ok(formatted, topic:, count: messages.size, timeout:)
        end
      rescue StandardError => e
        Result.fail("MQTT subscribe error: #{e.message}")
      end

      private

      def validate_topic(topic)
        mqtt_config = @config.mqtt

        blocked = mqtt_config.blocked_topics
        return "Blocked topic: #{topic} matches a blocked pattern" if topic_matches_any?(topic, blocked)

        allowed = mqtt_config.allowed_topics
        unless allowed.empty? || topic_matches_any?(topic, allowed)
          return "Topic not allowed: #{topic} does not match any allowed pattern"
        end

        nil
      end

      def topic_matches_any?(topic, patterns)
        patterns.any? { |pattern| mqtt_topic_match?(pattern, topic) }
      end

      def mqtt_topic_match?(pattern, topic)
        pattern_parts = pattern.split("/")
        topic_parts = topic.split("/")

        pattern_parts.each_with_index do |part, i|
          case part
          when "#"
            return true
          when "+"
            return false if i >= topic_parts.size
          else
            return false if i >= topic_parts.size || topic_parts[i] != part
          end
        end

        pattern_parts.size == topic_parts.size
      end

      def collect_messages(mqtt_config, topic:, count:, timeout:)
        messages = []

        client = MQTT::Client.new(
          host: mqtt_config.broker_host,
          port: mqtt_config.broker_port,
          username: mqtt_config.username.empty? ? nil : mqtt_config.username,
          password: mqtt_config.password.empty? ? nil : mqtt_config.password,
          client_id: "#{mqtt_config.client_id}-sub-#{SecureRandom.hex(4)}"
        )

        client.connect
        client.subscribe(topic)

        deadline = Time.now + timeout

        while messages.size < count && Time.now < deadline
          remaining = deadline - Time.now
          break if remaining <= 0

          begin
            msg_topic, msg_payload = client.get(topic, timeout: [remaining, 1.0].min)
            messages << { topic: msg_topic, payload: msg_payload, received_at: Time.now } if msg_topic
          rescue Timeout::Error
            # Normal timeout, continue loop to check deadline
          rescue MQTT::ProtocolException
            break
          end
        end

        client.disconnect
        messages
      rescue StandardError
        messages # Return whatever we collected
      end
    end
  end
end
