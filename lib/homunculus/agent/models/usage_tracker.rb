# frozen_string_literal: true

require "json"
require "fileutils"
require "monitor"

module Homunculus
  module Agent
    module Models
      # Tracks LLM usage metrics: tokens, costs, latency, and escalations.
      # Persists records to JSONL files organized by date.
      # Thread-safe via Monitor mixin.
      class UsageTracker
        include MonitorMixin

        attr_reader :storage_dir

        def initialize(storage_dir: "workspace/memory/llm_usage")
          super() # MonitorMixin requires this
          @storage_dir = storage_dir
          @logger = SemanticLogger["UsageTracker"]
          FileUtils.mkdir_p(@storage_dir)
        end

        # Record a Models::Response to the daily JSONL log.
        # @param response [Models::Response]
        # @param skill [String, nil] Active skill name
        def record(response, skill: nil)
          synchronize do
            record_hash = {
              ts: Time.now.iso8601,
              model: response.model,
              provider: response.provider.to_s,
              tier: response.tier.to_s,
              tokens_in: response.usage[:prompt_tokens] || 0,
              tokens_out: response.usage[:completion_tokens] || 0,
              latency_ms: response.latency_ms,
              cost_usd: response.cost_usd,
              skill: skill,
              escalated_from: response.escalated_from&.to_s,
              finish_reason: response.finish_reason.to_s
            }

            File.open(daily_file_path, "a") do |f|
              f.puts(JSON.generate(record_hash))
            end

            @logger.debug("Usage recorded", model: response.model, cost_usd: response.cost_usd)
          end
        rescue StandardError => e
          @logger.error("Failed to record usage", error: e.message)
        end

        # Aggregate summary for a specific date.
        # @param date [Date]
        # @return [Hash]
        def daily_summary(date = Date.today)
          records = load_records(date)
          aggregate(records)
        end

        # Total cloud spend for the current month.
        # @return [Float]
        def monthly_cloud_spend_usd
          total = 0.0
          today = Date.today
          first_of_month = Date.new(today.year, today.month, 1)

          (first_of_month..today).each do |date|
            records = load_records(date)
            total += records
                     .select { |r| r["provider"] == "anthropic" }
                     .sum { |r| r["cost_usd"] || 0.0 }
          end

          total
        end

        # Full monthly breakdown by provider and model.
        # @return [Hash]
        def monthly_summary
          today = Date.today
          first_of_month = Date.new(today.year, today.month, 1)
          all_records = []

          (first_of_month..today).each do |date|
            all_records.concat(load_records(date))
          end

          aggregate(all_records)
        end

        # Per-model performance stats for the given period.
        # @param period [Symbol] :day or :month
        # @return [Hash] model => {calls:, avg_latency_ms:, total_tokens:, total_cost_usd:}
        def model_stats(period: :month)
          records = case period
                    when :day then load_records(Date.today)
                    when :month
                      today = Date.today
                      first = Date.new(today.year, today.month, 1)
                      (first..today).flat_map { |d| load_records(d) }
                    else
                      []
                    end

          records.group_by { |r| r["model"] }.transform_values do |model_records|
            latencies = model_records.map { |r| r["latency_ms"] || 0 }
            {
              calls: model_records.size,
              avg_latency_ms: latencies.empty? ? 0 : (latencies.sum.to_f / latencies.size).round,
              total_tokens: model_records.sum { |r| (r["tokens_in"] || 0) + (r["tokens_out"] || 0) },
              total_cost_usd: model_records.sum { |r| r["cost_usd"] || 0.0 }.round(6)
            }
          end
        end

        # Budget status report.
        # @param monthly_limit [Float] Budget cap in USD
        # @return [Hash]
        def budget_status(monthly_limit: 30.0)
          spent = monthly_cloud_spend_usd
          {
            spent: spent.round(6),
            limit: monthly_limit,
            remaining: (monthly_limit - spent).round(6),
            percent: monthly_limit.positive? ? ((spent / monthly_limit) * 100).round(1) : 0.0
          }
        end

        private

        def daily_file_path(date = Date.today)
          File.join(@storage_dir, "#{date.strftime("%Y-%m-%d")}.jsonl")
        end

        def load_records(date)
          path = daily_file_path(date)
          return [] unless File.exist?(path)

          File.readlines(path).filter_map do |line|
            JSON.parse(line.strip)
          rescue JSON::ParserError
            nil
          end
        end

        def aggregate(records)
          {
            total_calls: records.size,
            total_tokens_in: records.sum { |r| r["tokens_in"] || 0 },
            total_tokens_out: records.sum { |r| r["tokens_out"] || 0 },
            total_cost_usd: records.sum { |r| r["cost_usd"] || 0.0 }.round(6),
            by_provider: records.group_by { |r| r["provider"] }.transform_values(&:size),
            by_tier: records.group_by { |r| r["tier"] }.transform_values(&:size),
            escalations: records.count { |r| r["escalated_from"] },
            avg_latency_ms: records.empty? ? 0 : (records.sum { |r| r["latency_ms"] || 0 }.to_f / records.size).round
          }
        end
      end
    end
  end
end
