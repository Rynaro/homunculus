# frozen_string_literal: true

module Homunculus
  module Tools
    class DatetimeNow < Base
      tool_name "datetime_now"
      description "Returns the current date and time in the user's timezone."
      trust_level :trusted

      parameter :timezone, type: :string,
                           description: "IANA timezone (e.g. America/New_York, Europe/London). Defaults to TZ env var.",
                           required: false

      def execute(arguments:, session:)
        tz = arguments[:timezone] || ENV.fetch("TZ", "UTC")

        # Use the TZ environment to format time
        time = if tz
                 ENV["TZ"].then do |original_tz|
                   ENV["TZ"] = tz
                   t = Time.now
                   ENV["TZ"] = original_tz
                   t
                 end
               else
                 Time.now
               end

        Result.ok(time.strftime("%Y-%m-%d %H:%M:%S %Z (#{tz})"))
      rescue StandardError => e
        Result.fail("Failed to get datetime: #{e.message}")
      end
    end
  end
end
