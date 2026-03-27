# frozen_string_literal: true

module Homunculus
  module Familiars
    # Routes a single notify() call to all enabled channels in the registry.
    # Each channel is isolated — one channel's failure never blocks the others.
    # Thread-safe: delivery tracking is protected by a Mutex.
    class Dispatcher
      include SemanticLogger::Loggable

      def initialize(registry:)
        @registry = registry
        @mutex = Mutex.new
        @delivery_counts = Hash.new(0)
        @failure_counts  = Hash.new(0)
      end

      # Dispatch a notification to all enabled channels.
      #
      # @param title    [String]
      # @param message  [String]
      # @param priority [:low, :normal, :high]
      # @return [Hash<Symbol, :delivered | :failed>] per-channel result
      def notify(title:, message:, priority: :normal)
        results = {}

        @registry.each_enabled do |channel|
          result = deliver_to(channel, title:, message:, priority:)
          results[channel.name] = result

          @mutex.synchronize do
            if result == :delivered
              @delivery_counts[channel.name] += 1
            else
              @failure_counts[channel.name] += 1
            end
          end
        end

        results
      end

      # Return health and delivery stats for all registered channels.
      # @return [Hash<Symbol, Hash>]
      def status
        @registry.channel_names.each_with_object({}) do |name, hash|
          channel = @registry.get(name)
          hash[name] = {
            enabled: channel.enabled?,
            healthy: channel.healthy?,
            deliveries: @mutex.synchronize { @delivery_counts[name] },
            failures: @mutex.synchronize { @failure_counts[name] }
          }
        end
      end

      private

      def deliver_to(channel, title:, message:, priority:)
        channel.deliver(title:, message:, priority:)
      rescue StandardError => e
        logger.error(
          "Familiars channel delivery failed",
          channel: channel.name,
          error: e.message,
          title:
        )
        :failed
      end
    end
  end
end
