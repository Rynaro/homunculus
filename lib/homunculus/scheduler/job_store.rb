# frozen_string_literal: true

require "sequel"
require "fileutils"
require "oj"

module Homunculus
  module Scheduler
    # Persists scheduled job definitions to SQLite so they survive restarts.
    # This stores the *definitions* (name, type, schedule, prompt, notify flag),
    # not the runtime state — rufus-scheduler handles that in-memory.
    class JobStore
      include SemanticLogger::Loggable

      def initialize(db_path:)
        FileUtils.mkdir_p(File.dirname(db_path))
        @db = Sequel.sqlite(db_path)
        create_tables!
      end

      # Persist a job definition
      def save_job(name:, type:, schedule:, agent_prompt:, notify: true, metadata: {})
        now = Time.now

        if @db[:scheduler_jobs].where(name:).any?
          @db[:scheduler_jobs].where(name:).update(
            type:,
            schedule:,
            agent_prompt:,
            notify: notify ? 1 : 0,
            metadata: Oj.dump(metadata, mode: :compat),
            updated_at: now
          )
        else
          @db[:scheduler_jobs].insert(
            name:,
            type:,
            schedule:,
            agent_prompt:,
            notify: notify ? 1 : 0,
            metadata: Oj.dump(metadata, mode: :compat),
            paused: 0,
            created_at: now,
            updated_at: now
          )
        end

        logger.info("Job saved", name:, type:, schedule:)
      end

      # Remove a job definition
      def remove_job(name)
        count = @db[:scheduler_jobs].where(name:).delete
        logger.info("Job removed", name:, found: count.positive?)
        count.positive?
      end

      # Load all persisted job definitions
      def all_jobs
        @db[:scheduler_jobs].all.map do |row|
          {
            name: row[:name],
            type: row[:type],
            schedule: row[:schedule],
            agent_prompt: row[:agent_prompt],
            notify: row[:notify] == 1,
            paused: row[:paused] == 1,
            metadata: Oj.load(row[:metadata] || "{}", mode: :compat),
            created_at: row[:created_at],
            updated_at: row[:updated_at]
          }
        end
      end

      # Mark a job as paused
      def pause_job(name)
        @db[:scheduler_jobs].where(name:).update(paused: 1, updated_at: Time.now)
      end

      # Mark a job as resumed
      def resume_job(name)
        @db[:scheduler_jobs].where(name:).update(paused: 0, updated_at: Time.now)
      end

      # Record a job execution for auditing and debugging
      def record_execution(name:, status:, duration_ms: nil, result_summary: nil)
        @db[:scheduler_executions].insert(
          job_name: name,
          status:,
          duration_ms:,
          result_summary: result_summary&.slice(0, 1000),
          executed_at: Time.now
        )

        # Keep only last 100 executions per job to avoid unbounded growth
        prune_executions(name)
      end

      # Get recent executions for a job
      def recent_executions(name, limit: 10)
        @db[:scheduler_executions]
          .where(job_name: name)
          .order(Sequel.desc(:executed_at))
          .limit(limit)
          .all
      end

      # Number of stored jobs
      def count
        @db[:scheduler_jobs].count
      end

      private

      def create_tables!
        @db.create_table?(:scheduler_jobs) do
          primary_key :id
          String :name, null: false, unique: true
          String :type, null: false # "cron" or "interval"
          String :schedule, null: false       # cron expression or interval string
          Text :agent_prompt, null: false
          Integer :notify, default: 1         # SQLite boolean
          Integer :paused, default: 0         # SQLite boolean
          Text :metadata, default: "{}"       # JSON blob for extra data
          DateTime :created_at
          DateTime :updated_at
        end

        @db.create_table?(:scheduler_executions) do
          primary_key :id
          String :job_name, null: false
          String :status, null: false         # "completed", "error", "heartbeat_ok"
          Integer :duration_ms
          String :result_summary
          DateTime :executed_at

          index :job_name
          index :executed_at
        end
      end

      def prune_executions(name)
        ids = @db[:scheduler_executions]
              .where(job_name: name)
              .order(Sequel.desc(:executed_at))
              .offset(100)
              .select(:id)

        @db[:scheduler_executions].where(id: ids).delete
      end
    end
  end
end
