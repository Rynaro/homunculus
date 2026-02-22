# frozen_string_literal: true

require "rufus-scheduler"

module Homunculus
  module Scheduler
    # Wraps rufus-scheduler with SQLite job persistence and notification integration.
    #
    # Jobs are defined as cron or interval schedules. Each job execution:
    # 1. Creates a new Session with source: :scheduler
    # 2. Runs the agent_prompt through the agent loop
    # 3. Delivers the result via the notification system (if notify: true)
    # 4. Records the execution in the job store
    class Manager
      include SemanticLogger::Loggable

      def initialize(config:, agent_loop:, notification:, job_store:)
        @scheduler = Rufus::Scheduler.new
        @agent_loop = agent_loop
        @notification = notification
        @job_store = job_store
        @config = config
        @running = false

        # Schedule queue flush at the start of active hours
        setup_queue_flush!
      end

      # Start the scheduler and restore persisted jobs
      def start
        @running = true
        restore_jobs!
        logger.info("Scheduler started", job_count: @job_store.count)
      end

      # Stop the scheduler gracefully
      def stop
        @running = false
        @scheduler.shutdown(:wait)
        logger.info("Scheduler stopped")
      end

      # Add a cron job (e.g., "0 9 * * 1-5" for weekday mornings)
      def add_cron_job(name:, cron:, agent_prompt:, notify: true, persist: true)
        # Persist first so it survives restarts
        if persist
          @job_store.save_job(
            name:, type: "cron", schedule: cron,
            agent_prompt:, notify:
          )
        end

        schedule_cron(name:, cron:, agent_prompt:, notify:)
        logger.info("Cron job added", name:, cron:)
      end

      # Add an interval job (runs every N minutes)
      def add_interval_job(name:, interval_minutes:, agent_prompt:, notify: true, persist: true)
        schedule_str = "#{interval_minutes}m"

        if persist
          @job_store.save_job(
            name:, type: "interval", schedule: schedule_str,
            agent_prompt:, notify:
          )
        end

        schedule_interval(name:, interval: schedule_str, agent_prompt:, notify:)
        logger.info("Interval job added", name:, interval: schedule_str)
      end

      # Add a one-shot job that fires once after a delay (ephemeral, not persisted)
      def add_one_shot_job(name:, delay:, agent_prompt:, notify: true)
        @scheduler.in(delay, name: name) do
          execute_job(name: name, agent_prompt: agent_prompt, notify: notify)
        end
        logger.info("One-shot job added", name: name, delay: delay)
      end

      # Remove a job (from scheduler and store)
      def remove_job(name)
        rufus_job = find_rufus_job(name)
        rufus_job&.unschedule
        @job_store.remove_job(name)
        logger.info("Job removed", name:)
      end

      # List all jobs with their next run time
      def list_jobs
        @scheduler.jobs.map do |j|
          {
            name: j.name || j.id,
            next_time: j.next_time&.to_s,
            paused: j.paused?,
            type: j.is_a?(Rufus::Scheduler::CronJob) ? "cron" : "interval"
          }
        end
      end

      # Pause a job
      def pause_job(name)
        find_rufus_job(name)&.pause
        @job_store.pause_job(name)
        logger.info("Job paused", name:)
      end

      # Resume a job
      def resume_job(name)
        find_rufus_job(name)&.resume
        @job_store.resume_job(name)
        logger.info("Job resumed", name:)
      end

      # Delegate to job store for recent execution history
      def recent_executions(name, limit: 5)
        @job_store.recent_executions(name, limit:)
      end

      # Is the scheduler running?
      def running?
        @running && !@scheduler.down?
      end

      # Status summary
      def status
        {
          running: running?,
          job_count: @scheduler.jobs.size,
          persisted_count: @job_store.count,
          queue_size: @notification.queue_size,
          active_hours: @notification.active_hours?
        }
      end

      private

      def restore_jobs!
        @job_store.all_jobs.each do |job|
          case job[:type]
          when "cron"
            schedule_cron(
              name: job[:name], cron: job[:schedule],
              agent_prompt: job[:agent_prompt], notify: job[:notify]
            )
            find_rufus_job(job[:name])&.pause if job[:paused]
          when "interval"
            schedule_interval(
              name: job[:name], interval: job[:schedule],
              agent_prompt: job[:agent_prompt], notify: job[:notify]
            )
            find_rufus_job(job[:name])&.pause if job[:paused]
          else
            logger.warn("Unknown job type during restore", name: job[:name], type: job[:type])
          end
        end

        logger.info("Jobs restored from store", count: @job_store.count)
      end

      def schedule_cron(name:, cron:, agent_prompt:, notify:)
        tz = @config.scheduler.heartbeat.timezone

        @scheduler.cron(cron, name:, overlap: false, timezone: tz) do
          execute_job(name:, agent_prompt:, notify:)
        end
      end

      def schedule_interval(name:, interval:, agent_prompt:, notify:)
        @scheduler.every(interval, name:, overlap: false) do
          execute_job(name:, agent_prompt:, notify:)
        end
      end

      def execute_job(name:, agent_prompt:, notify:)
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        logger.info("Job executing", name:)

        session = Session.new
        session.source = :scheduler

        result = @agent_loop.run(agent_prompt, session)
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round

        if result.completed?
          response = result.response || ""

          # HEARTBEAT_OK responses are never notified, just logged
          if heartbeat_ok?(response)
            @job_store.record_execution(
              name:, status: "heartbeat_ok",
              duration_ms:, result_summary: response.slice(0, 200)
            )
            logger.info("Job completed (HEARTBEAT_OK)", name:, duration_ms:)
          elsif notify
            @notification.notify(response)
            @job_store.record_execution(
              name:, status: "completed",
              duration_ms:, result_summary: response.slice(0, 200)
            )
            logger.info("Job completed and notified", name:, duration_ms:)
          else
            @job_store.record_execution(
              name:, status: "completed",
              duration_ms:, result_summary: response.slice(0, 200)
            )
            logger.info("Job completed (no notification)", name:, duration_ms:)
          end
        else
          error_msg = result.error || "Unknown error"
          @job_store.record_execution(
            name:, status: "error",
            duration_ms:, result_summary: error_msg
          )
          logger.error("Job failed", name:, error: error_msg, duration_ms:)
        end
      rescue StandardError => e
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
        @job_store.record_execution(
          name:, status: "error",
          duration_ms:, result_summary: e.message
        )
        logger.error("Job execution error", name:, error: e.message,
                                            backtrace: e.backtrace&.first(5))
      end

      def heartbeat_ok?(response)
        response.match?(/\bHEARTBEAT_OK\b/i)
      end

      def find_rufus_job(name)
        @scheduler.jobs.find { |j| j.name == name }
      end

      # Schedule a job to flush the notification queue at the start of active hours
      def setup_queue_flush!
        start_hour = @config.scheduler.heartbeat.active_hours_start
        tz = @config.scheduler.heartbeat.timezone

        @scheduler.cron("0 #{start_hour} * * *", name: "_queue_flush", timezone: tz) do
          count = @notification.flush_queue
          logger.info("Queue flush at active hours start", delivered: count) if count.positive?
        end
      end
    end
  end
end
