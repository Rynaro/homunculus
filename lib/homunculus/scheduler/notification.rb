# frozen_string_literal: true

module Homunculus
  module Scheduler
    # Handles notification delivery with priority levels, quiet hours, and rate limiting.
    #
    # Priority levels:
    #   :low    — log only, never send to Telegram
    #   :normal — send via Telegram during active hours
    #   :high   — send via Telegram + mark as persistent (always delivered, even quiet hours)
    #
    # Quiet hours: notifications queued during inactive hours, flushed at next active period.
    # Rate limiting: max N notifications per hour (configurable).
    class Notification
      include SemanticLogger::Loggable

      PRIORITIES = %i[low normal high].freeze

      def initialize(config:, deliver_fn: nil)
        @heartbeat_config = config.scheduler.heartbeat
        @notification_config = config.scheduler.notification
        @deliver_fn = deliver_fn  # ->(text, priority) { ... }
        @queue = []               # Queued notifications for quiet hours
        @delivery_log = []        # Timestamps of recent deliveries for rate limiting
        @mutex = Mutex.new
      end

      # Set the delivery function (called after initialization, e.g., when Telegram is ready)
      attr_writer :deliver_fn

      # Send a notification with the given priority.
      # Returns :delivered, :queued, :rate_limited, or :logged
      def notify(text, priority: :normal)
        priority = priority.to_sym
        unless PRIORITIES.include?(priority)
          logger.warn("Invalid priority, defaulting to :normal", given: priority)
          priority = :normal
        end

        # Low priority: log only
        if priority == :low
          logger.info("Notification (low priority)", text: text.slice(0, 200))
          return :logged
        end

        # High priority: always deliver immediately (bypass quiet hours)
        return deliver_now(text, priority) if priority == :high

        # Normal priority: respect quiet hours and rate limits
        if quiet_hours?
          if @notification_config.quiet_hours_queue
            queue_notification(text, priority)
            return :queued
          else
            logger.info("Notification dropped (quiet hours, queuing disabled)",
                        text: text.slice(0, 200))
            return :logged
          end
        end

        deliver_now(text, priority)
      end

      # Flush queued notifications (called when active hours start).
      # Returns count of flushed notifications.
      def flush_queue
        notifications = @mutex.synchronize { @queue.dup.tap { @queue.clear } }

        return 0 if notifications.empty?

        logger.info("Flushing notification queue", count: notifications.size)

        delivered = 0
        notifications.each do |entry|
          result = deliver_now(entry[:text], entry[:priority])
          delivered += 1 if result == :delivered
        end

        delivered
      end

      # Check if we're currently in quiet hours
      def quiet_hours?
        now = current_time_in_timezone
        hour = now.hour
        hour < @heartbeat_config.active_hours_start || hour >= @heartbeat_config.active_hours_end
      end

      # Check if we're currently in active hours
      def active_hours?
        !quiet_hours?
      end

      # Number of queued notifications
      def queue_size
        @mutex.synchronize { @queue.size }
      end

      # Number of deliveries in the last hour
      def deliveries_last_hour
        cutoff = Time.now - 3600
        @mutex.synchronize { @delivery_log.count { |t| t > cutoff } }
      end

      private

      def deliver_now(text, priority)
        if rate_limited?
          logger.warn("Notification rate limited", deliveries_last_hour: deliveries_last_hour)
          # Queue it for later if rate limited
          queue_notification(text, priority)
          return :rate_limited
        end

        if @deliver_fn
          begin
            @deliver_fn.call(text, priority)
            record_delivery
            logger.info("Notification delivered", priority:, length: text.length)
            :delivered
          rescue StandardError => e
            logger.error("Notification delivery failed", error: e.message, priority:)
            queue_notification(text, priority)
            :queued
          end
        else
          logger.info("No delivery function configured, logging notification",
                      priority:, text: text.slice(0, 200))
          :logged
        end
      end

      def queue_notification(text, priority)
        @mutex.synchronize do
          @queue << { text:, priority:, queued_at: Time.now }
          logger.info("Notification queued", priority:, queue_size: @queue.size)
        end
      end

      def rate_limited?
        max = @notification_config.max_per_hour
        deliveries_last_hour >= max
      end

      def record_delivery
        @mutex.synchronize do
          @delivery_log << Time.now
          # Prune entries older than 1 hour
          cutoff = Time.now - 3600
          @delivery_log.reject! { |t| t < cutoff }
        end
      end

      def current_time_in_timezone
        tz = @heartbeat_config.timezone
        # Use TZInfo if available, otherwise fall back to ENV-based approach
        if defined?(TZInfo)
          TZInfo::Timezone.get(tz).now
        else
          # Simple fallback: use UTC offset based on known timezone
          utc_now = Time.now.utc
          offset = timezone_offset(tz)
          utc_now + offset
        end
      rescue StandardError => e
        logger.warn("Timezone lookup failed, using local time", timezone: tz, error: e.message)
        Time.now
      end

      # Simple offset mapping for common timezones.
      # rufus-scheduler brings in et-orbi which includes TZInfo,
      # so this is mainly a safety fallback.
      def timezone_offset(tz)
        case tz
        when "America/Sao_Paulo" then -3 * 3600
        when "America/New_York" then -5 * 3600
        when "America/Chicago" then -6 * 3600
        when "America/Los_Angeles" then -8 * 3600
        when "Europe/London" then 0
        when "Europe/Berlin" then 1 * 3600
        when "Asia/Tokyo" then 9 * 3600
        when "UTC" then 0
        else 0
        end
      end
    end
  end
end
