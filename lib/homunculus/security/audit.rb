# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"

module Homunculus
  module Security
    # Class-based audit logger with thread-safe file writes
    class AuditLogger
      def initialize(path)
        @path = Pathname.new(path)
        @path.dirname.mkpath
        @mutex = Mutex.new
      end

      def log(**fields)
        entry = {
          ts: Time.now.utc.iso8601(6),
          **fields
        }.compact

        @mutex.synchronize do
          File.open(@path, "a") do |f|
            f.flock(File::LOCK_EX)
            f.puts(JSON.generate(entry))
          end
        end

        entry
      end

      def log_tool_exec(tool_call:, result:, session_id:, model:, confirmed: nil, duration_ms: nil)
        log(
          session_id:,
          action: "tool_exec",
          tool: tool_call.name,
          input_hash: hash_value(tool_call.arguments),
          output_hash: result ? hash_value(result.to_s) : nil,
          confirmed:,
          model:,
          duration_ms:
        )
      end

      def log_completion(session_id:, model:, input_tokens:, output_tokens:, stop_reason:, duration_ms:)
        log(
          session_id:,
          action: "completion",
          model:,
          tokens_in: input_tokens,
          tokens_out: output_tokens,
          stop_reason:,
          duration_ms:
        )
      end

      private

      def hash_value(value)
        return nil if value.nil?

        Digest::SHA256.hexdigest(value.to_s)[0..15]
      end
    end

    # Keep backward-compatible module interface for existing code
    module Audit
      module_function

      def log(action_type:, session_id: nil, tool_name: nil, input: nil, output: nil, model_used: nil, **extra)
        entry = {
          timestamp: Time.now.utc.iso8601(6),
          session_id:,
          action_type:,
          tool_name:,
          input_hash: input ? Digest::SHA256.hexdigest(input.to_s)[0..15] : nil,
          output_hash: output ? Digest::SHA256.hexdigest(output.to_s)[0..15] : nil,
          model_used:,
          **extra
        }.compact

        append_entry(entry)
      end

      def log_path
        @log_path || default_log_path
      end

      def log_path=(path)
        @log_path = path
      end

      def reset!
        @log_path = nil
      end

      def append_entry(entry)
        path = log_path
        FileUtils.mkdir_p(File.dirname(path))

        File.open(path, "a") do |f|
          f.flock(File::LOCK_EX)
          f.puts(JSON.generate(entry))
        end
      end

      def default_log_path
        "data/audit.jsonl"
      end

      private_class_method :append_entry, :default_log_path
    end
  end
end
