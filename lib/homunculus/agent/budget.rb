# frozen_string_literal: true

require "sequel"

module Homunculus
  module Agent
    # Tracks API usage costs and enforces daily budget limits.
    # Uses SQLite for persistence (following the scheduler/memory DB pattern).
    class BudgetTracker
      include SemanticLogger::Loggable

      # Claude Sonnet 4 pricing: Input $3/MTok, Output $15/MTok
      INPUT_COST_PER_TOKEN  = 3.0 / 1_000_000
      OUTPUT_COST_PER_TOKEN = 15.0 / 1_000_000

      def initialize(daily_limit_usd:, db:)
        @daily_limit = daily_limit_usd
        @db = db
        ensure_schema!
      end

      # Records a completed API call's token usage and cost.
      def record_usage(model:, input_tokens:, output_tokens:)
        cost = calculate_cost(input_tokens, output_tokens)

        @db[:api_usage].insert(
          model: model.to_s,
          input_tokens:,
          output_tokens:,
          cost_usd: cost,
          recorded_at: Time.now.utc.iso8601
        )

        logger.info("API usage recorded",
                    model:, input_tokens:, output_tokens:, cost_usd: cost.round(6))
        cost
      end

      # Total cost spent today (UTC).
      def spent_today
        today_start = Date.today.to_time.utc.iso8601

        @db[:api_usage]
          .where { recorded_at >= today_start }
          .sum(:cost_usd) || 0.0
      end

      # Remaining budget for today.
      def remaining_today
        @daily_limit - spent_today
      end

      # Whether the budget allows a Claude call of the given estimated size.
      def can_use_claude?(estimated_tokens: 4000)
        estimated_cost = estimated_tokens * INPUT_COST_PER_TOKEN
        remaining_today > estimated_cost
      end

      # Summary hash for display in /budget and /status commands.
      def usage_summary
        {
          daily_limit_usd: @daily_limit,
          spent_today_usd: spent_today.round(4),
          remaining_usd: remaining_today.round(4),
          can_use_claude: can_use_claude?
        }
      end

      private

      def calculate_cost(input_tokens, output_tokens)
        (input_tokens * INPUT_COST_PER_TOKEN) + (output_tokens * OUTPUT_COST_PER_TOKEN)
      end

      def ensure_schema!
        @db.create_table?(:api_usage) do
          primary_key :id
          String :model, null: false
          Integer :input_tokens, default: 0
          Integer :output_tokens, default: 0
          Float :cost_usd, default: 0.0
          String :recorded_at, null: false
          index :recorded_at
        end
      end
    end
  end
end
