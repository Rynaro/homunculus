# frozen_string_literal: true

module Homunculus
  module Tools
    # Agent-callable tool to send a notification through the Familiars dispatcher.
    # Elevated: requires user confirmation before sending.
    # Trust level: :mixed — agent-generated content sent to external system.
    class SendNotification < Base
      tool_name "send_notification"
      description "Send a push notification to the user via Familiars. " \
                  "Use this to proactively alert the user during autonomous operation. " \
                  "Requires user confirmation."
      trust_level :mixed
      requires_confirmation true

      parameter :title, type: :string,
                        description: "Short notification title (displayed as headline)"
      parameter :message, type: :string,
                          description: "Notification body text"
      parameter :priority, type: :string,
                           description: "Priority level: low, normal, or high",
                           required: false,
                           enum: %w[low normal high]

      def initialize(familiars_dispatcher:)
        @familiars_dispatcher = familiars_dispatcher
      end

      def execute(arguments:, session:)
        title   = arguments[:title]
        message = arguments[:message]
        priority = (arguments[:priority] || "normal").to_sym

        return Result.fail("Missing required parameter: title") unless title && !title.strip.empty?
        return Result.fail("Missing required parameter: message") unless message && !message.strip.empty?

        unless @familiars_dispatcher
          return Result.fail("Familiars not enabled — configure [familiars] enabled = true to use send_notification")
        end

        valid_priorities = %i[low normal high]
        unless valid_priorities.include?(priority)
          return Result.fail("Invalid priority '#{priority}'. Must be one of: #{valid_priorities.join(", ")}")
        end

        results = @familiars_dispatcher.notify(
          title: title.strip,
          message: message.strip,
          priority: priority
        )

        delivered = results.count { |_, r| r == :delivered }
        failed    = results.count { |_, r| r == :failed }

        if delivered.positive?
          Result.ok(
            "Notification sent: '#{title}' (priority: #{priority}). " \
            "Delivered to #{delivered} channel(s)#{", #{failed} failed" if failed.positive?}."
          )
        else
          Result.fail("Notification delivery failed on all channels (#{failed} failure(s)). " \
                      "Check Familiars configuration and channel health.")
        end
      rescue StandardError => e
        Result.fail("send_notification error: #{e.message}")
      end
    end
  end
end
