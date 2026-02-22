# frozen_string_literal: true

require "open3"
require "json"
require "shellwords"

module Homunculus
  module Security
    class Sandbox
      include Utils::Logging

      TIMEOUT_SECONDS = 30

      def initialize(config:)
        @config = config.tools.sandbox
      end

      def execute(command, timeout: TIMEOUT_SECONDS)
        validate_command!(command)

        logger.info("Sandbox executing", command: command[0..100])

        if @config.enabled
          docker_execute(command, timeout:)
        else
          logger.warn("Sandbox disabled — executing directly")
          local_execute(command, timeout:)
        end
      end

      private

      def validate_command!(command)
        blocked = blocked_patterns
        blocked.each do |pattern|
          raise SecurityError, "Blocked command pattern detected: #{pattern}" if command.include?(pattern)
        end
      end

      def blocked_patterns
        # Load from parent tools config; default fallback
        ["rm -rf /", "mkfs", "dd if=", "> /dev/"]
      end

      def docker_execute(command, timeout:)
        docker_cmd = build_docker_command(command)

        stdout, stderr, status = Open3.capture3(*docker_cmd, timeout:)

        {
          stdout: stdout.strip,
          stderr: stderr.strip,
          exit_code: status.exitstatus,
          timed_out: false
        }
      rescue Timeout::Error
        { stdout: "", stderr: "Command timed out after #{timeout}s", exit_code: -1, timed_out: true }
      end

      def local_execute(command, timeout:)
        stdout, stderr, status = Open3.capture3(command, timeout:)

        {
          stdout: stdout.strip,
          stderr: stderr.strip,
          exit_code: status.exitstatus,
          timed_out: false
        }
      rescue Timeout::Error
        { stdout: "", stderr: "Command timed out after #{timeout}s", exit_code: -1, timed_out: true }
      end

      def build_docker_command(command)
        args = ["docker", "run", "--rm"]
        args += ["--network", @config.network]
        args += ["--memory", @config.memory_limit]
        args += ["--cpus", @config.cpu_limit]
        args += ["--read-only"] if @config.read_only_root
        args += ["--security-opt", "no-new-privileges:true"] if @config.no_new_privileges

        @config.drop_capabilities.each do |cap|
          args += ["--cap-drop", cap]
        end

        args += ["--tmpfs", "/tmp:size=50M"]
        args += [@config.image]
        args += ["/bin/sh", "-c", command]

        args
      end
    end
  end
end
