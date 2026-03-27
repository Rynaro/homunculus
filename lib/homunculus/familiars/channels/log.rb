# frozen_string_literal: true

module Homunculus
  module Familiars
    module Channels
      # Always-on fallback channel that writes notifications to SemanticLogger.
      # Provides an audit trail of all dispatched notifications regardless of
      # which other channels are configured.
      class Log < Channel
        def name
          :log
        end

        # Always enabled — the log channel cannot be turned off.
        def enabled?
          true
        end

        # Always healthy — writing to the logger cannot fail in isolation.
        def healthy?
          true
        end

        # Write the notification to SemanticLogger at :info level.
        def deliver(title:, message:, priority: :normal)
          logger.info(
            "Familiars notification",
            title:,
            priority:,
            message: message.slice(0, 500),
            timestamp: Time.now.utc.iso8601
          )
          :delivered
        rescue StandardError => e
          logger.error("Log channel delivery failed", error: e.message)
          :failed
        end
      end
    end
  end
end
