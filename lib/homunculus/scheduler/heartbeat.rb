# frozen_string_literal: true

module Homunculus
  module Scheduler
    # Reads workspace/HEARTBEAT.md and registers it as a scheduled agent prompt.
    #
    # The heartbeat is a cron job that feeds the HEARTBEAT.md checklist to the agent.
    # The agent evaluates each item against the current time and day-of-week to
    # determine if any reminders should fire. Returns either:
    #   - HEARTBEAT_OK: no reminders due right now (not notified, just logged)
    #   - A notification message listing reminders that are due
    class Heartbeat
      include SemanticLogger::Loggable

      HEARTBEAT_FILE = "HEARTBEAT.md"
      JOB_NAME = "heartbeat"

      def initialize(config:, scheduler_manager:)
        @config = config
        @heartbeat_config = config.scheduler.heartbeat
        @scheduler_manager = scheduler_manager
        @workspace_path = config.agent.workspace_path
      end

      # Register the heartbeat cron job if enabled and HEARTBEAT.md exists
      def setup!
        unless @heartbeat_config.enabled
          logger.info("Heartbeat disabled in config")
          return false
        end

        checklist = load_checklist
        unless checklist
          logger.warn("Heartbeat enabled but HEARTBEAT.md not found",
                      expected_path: heartbeat_path)
          return false
        end

        prompt = build_prompt(checklist)

        @scheduler_manager.add_cron_job(
          name: JOB_NAME,
          cron: @heartbeat_config.cron,
          agent_prompt: prompt,
          notify: true,
          persist: false # Heartbeat is config-driven, not user-created
        )

        logger.info("Heartbeat registered",
                    cron: @heartbeat_config.cron,
                    checklist_items: count_items(checklist))
        true
      end

      # Reload the heartbeat checklist (e.g., after workspace/HEARTBEAT.md changes)
      def reload!
        @scheduler_manager.remove_job(JOB_NAME)
        setup!
      end

      private

      def heartbeat_path
        File.join(@workspace_path, HEARTBEAT_FILE)
      end

      def load_checklist
        path = heartbeat_path
        return nil unless File.exist?(path)

        File.read(path)
      end

      def build_prompt(checklist)
        now = current_time
        <<~PROMPT
          You are performing a scheduled heartbeat check.

          Current time: #{now.strftime("%H:%M")} #{now.strftime("%A")} (#{@heartbeat_config.timezone})

          ## Instructions

          Evaluate each item in the checklist below against the current time and day.

          **Time matching:** A reminder is due if the current time is within a 30-minute window
          before the reminder's scheduled time. For example, if it is 12:45 and a reminder says
          "at 13:00", that reminder IS due. If it is 11:00, it is NOT due.

          **Day restrictions:**
          - "weekdays only" = Monday through Friday
          - "Monday only" = only on Mondays
          - Items without day restrictions apply every day

          **Prefixes** indicate the reminder category:
          - WK = Work tasks
          - HL = Personal tasks
          - FM = Family tasks
          - GL = Pets tasks

          **Tasks without a specific time** (e.g., "Summarize yesterday's tasks") should be
          evaluated once per day — treat them as due on the first heartbeat of the day (the
          earliest check during active hours).

          ## Response

          If NO items are due right now, respond with exactly: HEARTBEAT_OK

          If ANY items are due, respond with a concise notification listing each due reminder
          with its prefix and description. Do not include items that are not due.

          ---

          #{checklist}
        PROMPT
      end

      def current_time
        tz = @heartbeat_config.timezone
        TZInfo::Timezone.get(tz).now
      rescue StandardError
        Time.now
      end

      def count_items(checklist)
        checklist.scan(/^- \[ \]/).size
      end
    end
  end
end
