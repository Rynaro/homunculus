# frozen_string_literal: true

module Homunculus
  module Tools
    class SchedulerManage < Base
      include SemanticLogger::Loggable

      tool_name "scheduler_manage"
      description <<~DESC.strip
        Manage scheduled jobs: create reminders, recurring cron/interval jobs, list, pause, resume, remove, or check status.
        Use action "add_reminder" for one-shot delayed tasks (e.g., "remind me in 2 minutes").
        Use action "add_cron" for cron-scheduled recurring jobs.
        Use action "add_interval" for interval-based recurring jobs.
      DESC
      trust_level :untrusted
      requires_confirmation true

      ACTIONS = %w[add_reminder add_cron add_interval list status remove pause resume history].freeze
      DELAY_FORMAT = /\A(\d+[smhd])+\z/i

      parameter :action, type: :string,
                         description: "Action to perform: #{ACTIONS.join(", ")}",
                         enum: ACTIONS
      parameter :name, type: :string,
                       description: "Job identifier (required for all actions except list/status)",
                       required: false
      parameter :delay, type: :string,
                        description: 'Rufus duration for add_reminder, e.g. "2m", "1h30m"',
                        required: false
      parameter :cron, type: :string,
                       description: 'Cron expression for add_cron, e.g. "0 9 * * 1-5"',
                       required: false
      parameter :interval_minutes, type: :integer,
                                   description: "Interval in minutes for add_interval",
                                   required: false
      parameter :agent_prompt, type: :string,
                               description: "What the agent should do when the job fires (required for add_* actions)",
                               required: false
      parameter :notify, type: :boolean,
                         description: "Whether to send a notification when the job fires (default: true)",
                         required: false

      def initialize(scheduler_manager:)
        super()
        @manager = scheduler_manager
      end

      def execute(arguments:, session:)
        action = arguments[:action]
        return Result.fail("Missing required parameter: action") unless action
        return Result.fail("Unknown action: #{action}. Valid: #{ACTIONS.join(", ")}") unless ACTIONS.include?(action)

        send(:"execute_#{action}", arguments)
      rescue StandardError => e
        logger.error("Scheduler tool error", action:, error: e.message)
        Result.fail("Scheduler error: #{e.message}")
      end

      private

      # ── Add Actions ──────────────────────────────────────────────────

      def execute_add_reminder(args)
        name = args[:name]
        delay = args[:delay]
        agent_prompt = args[:agent_prompt]

        return Result.fail("Missing required parameter: name") unless name
        return Result.fail("Missing required parameter: delay") unless delay
        return Result.fail("Missing required parameter: agent_prompt") unless agent_prompt
        return Result.fail("Invalid delay format: #{delay}. Expected e.g. '2m', '1h30m', '5s'") unless delay.match?(DELAY_FORMAT)

        notify = args.fetch(:notify, true)

        @manager.add_one_shot_job(name:, delay:, agent_prompt:, notify:)
        Result.ok("Reminder '#{name}' scheduled to fire in #{delay}.")
      end

      def execute_add_cron(args)
        name = args[:name]
        cron = args[:cron]
        agent_prompt = args[:agent_prompt]

        return Result.fail("Missing required parameter: name") unless name
        return Result.fail("Missing required parameter: cron") unless cron
        return Result.fail("Missing required parameter: agent_prompt") unless agent_prompt

        notify = args.fetch(:notify, true)

        @manager.add_cron_job(name:, cron:, agent_prompt:, notify:)
        Result.ok("Cron job '#{name}' scheduled with expression '#{cron}'.")
      end

      def execute_add_interval(args)
        name = args[:name]
        interval_minutes = args[:interval_minutes]
        agent_prompt = args[:agent_prompt]

        return Result.fail("Missing required parameter: name") unless name
        return Result.fail("Missing required parameter: interval_minutes") unless interval_minutes
        return Result.fail("Missing required parameter: agent_prompt") unless agent_prompt

        notify = args.fetch(:notify, true)

        @manager.add_interval_job(name:, interval_minutes:, agent_prompt:, notify:)
        Result.ok("Interval job '#{name}' scheduled every #{interval_minutes} minutes.")
      end

      # ── Query Actions ────────────────────────────────────────────────

      def execute_list(_args)
        jobs = @manager.list_jobs

        if jobs.empty?
          Result.ok("No scheduled jobs.")
        else
          lines = jobs.map do |j|
            state = j[:paused] ? "paused" : "active"
            "- #{j[:name]} [#{j[:type]}] (#{state}) next: #{j[:next_time] || "N/A"}"
          end
          Result.ok("Scheduled jobs:\n#{lines.join("\n")}")
        end
      end

      def execute_status(_args)
        status = @manager.status
        Result.ok(
          "Scheduler status:\n  " \
          "Running: #{status[:running]}\n  " \
          "Jobs: #{status[:job_count]}\n  " \
          "Persisted: #{status[:persisted_count]}\n  " \
          "Queue: #{status[:queue_size]}\n  " \
          "Active hours: #{status[:active_hours]}"
        )
      end

      # ── Mutation Actions ─────────────────────────────────────────────

      def execute_remove(args)
        name = args[:name]
        return Result.fail("Missing required parameter: name") unless name

        @manager.remove_job(name)
        Result.ok("Job '#{name}' removed.")
      end

      def execute_pause(args)
        name = args[:name]
        return Result.fail("Missing required parameter: name") unless name

        @manager.pause_job(name)
        Result.ok("Job '#{name}' paused.")
      end

      def execute_resume(args)
        name = args[:name]
        return Result.fail("Missing required parameter: name") unless name

        @manager.resume_job(name)
        Result.ok("Job '#{name}' resumed.")
      end

      def execute_history(args)
        name = args[:name]
        return Result.fail("Missing required parameter: name") unless name

        executions = @manager.recent_executions(name)

        if executions.empty?
          Result.ok("No execution history for '#{name}'.")
        else
          lines = executions.map do |e|
            time = e[:executed_at]&.strftime("%Y-%m-%d %H:%M") || "?"
            "- #{time} [#{e[:status]}] (#{e[:duration_ms]}ms) #{e[:result_summary]&.slice(0, 80)}"
          end
          Result.ok("Recent executions for '#{name}':\n#{lines.join("\n")}")
        end
      end
    end
  end
end
