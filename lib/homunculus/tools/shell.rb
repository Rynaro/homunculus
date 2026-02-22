# frozen_string_literal: true

require "open3"
require "shellwords"

module Homunculus
  module Tools
    class ShellExec < Base
      include PathValidation

      tool_name "shell_exec"
      description <<~DESC.strip
        Execute a shell command in a sandboxed Docker container.
        The sandbox has: curl, jq, git, ripgrep, fd-find, python3, ruby.
        Network access is disabled by default. Use 'network: true' for commands needing internet.
        The working directory is /workspace (mounted read-only from agent workspace).
        /tmp is writable for temporary files.
      DESC
      trust_level :untrusted
      requires_confirmation true

      parameter :command, type: :string, description: "Shell command to execute"
      parameter :timeout, type: :integer, description: "Timeout in seconds (default: 30, max: 120)", required: false
      parameter :network, type: :boolean, description: "Enable network access (default: false)", required: false
      parameter :workdir, type: :string, description: "Working directory inside container (default: /workspace)",
                          required: false

      MAX_TIMEOUT = 120
      DEFAULT_TIMEOUT = 30
      MAX_OUTPUT_SIZE = 100_000 # 100KB output cap

      def initialize(config:)
        super()
        @config = config
      end

      def execute(arguments:, session:)
        command = arguments[:command]
        return Result.fail("Missing required parameter: command") unless command
        return Result.fail("Command must be a non-empty string") if command.strip.empty?

        # Check blocked patterns before any execution
        blocked = @config.tools.blocked_patterns
        return Result.fail("Blocked command pattern detected") if blocked.any? { |pattern| command.include?(pattern) }

        timeout = [arguments.fetch(:timeout, DEFAULT_TIMEOUT).to_i, MAX_TIMEOUT].min
        timeout = DEFAULT_TIMEOUT if timeout <= 0
        network = arguments.fetch(:network, false)
        workdir = arguments.fetch(:workdir, "/workspace")

        # Validate workdir is a safe container path (no escape from expected dirs)
        unless workdir.match?(%r{\A/[\w./-]+\z}) && !workdir.include?("..")
          return Result.fail("Invalid working directory: #{workdir}")
        end

        if @config.tools.sandbox.enabled
          docker_execute(command, timeout:, network:, workdir:)
        else
          local_execute(command, timeout:)
        end
      rescue StandardError => e
        Result.fail("Shell execution error: #{e.message}")
      end

      private

      def docker_execute(command, timeout:, network:, workdir:)
        docker_cmd = build_docker_command(command, network:, workdir:)

        stdout, stderr, status = Open3.capture3(*docker_cmd, timeout:)

        stdout = truncate_output(stdout)
        stderr = truncate_output(stderr)

        Result.ok(
          stdout.strip,
          exit_code: status.exitstatus,
          stderr: stderr.strip,
          timed_out: false
        )
      rescue Timeout::Error
        Result.fail("Command timed out after #{timeout}s", exit_code: -1, timed_out: true)
      end

      def local_execute(command, timeout:)
        stdout, stderr, status = Open3.capture3("/bin/sh", "-c", command, timeout:)

        stdout = truncate_output(stdout)
        stderr = truncate_output(stderr)

        Result.ok(
          stdout.strip,
          exit_code: status.exitstatus,
          stderr: stderr.strip,
          timed_out: false
        )
      rescue Timeout::Error
        Result.fail("Command timed out after #{timeout}s", exit_code: -1, timed_out: true)
      end

      def build_docker_command(command, network:, workdir:)
        sandbox = @config.tools.sandbox
        workspace_path = File.expand_path(@config.agent.workspace_path)

        args = ["docker", "run", "--rm"]

        # Network isolation (disabled by default)
        args += if network
                  ["--network", "bridge"]
                else
                  ["--network", "none"]
                end

        # Resource limits
        args += ["--memory", sandbox.memory_limit]
        args += ["--cpus", sandbox.cpu_limit]

        # Security hardening
        args += ["--read-only"] if sandbox.read_only_root
        args += ["--security-opt", "no-new-privileges:true"] if sandbox.no_new_privileges

        sandbox.drop_capabilities.each do |cap|
          args += ["--cap-drop", cap]
        end

        # Workspace mount (read-only)
        args += ["-v", "#{workspace_path}:/workspace:ro"]

        # Writable tmpfs
        args += ["--tmpfs", "/tmp:rw,noexec,nosuid,size=64m"]

        # Working directory
        args += ["-w", workdir]

        # Image and command
        args += [sandbox.image]
        args += ["/bin/sh", "-c", command]

        args
      end

      def truncate_output(output)
        return "" if output.nil?

        if output.bytesize > MAX_OUTPUT_SIZE
          output[0...MAX_OUTPUT_SIZE] + "\n... (output truncated at #{MAX_OUTPUT_SIZE} bytes)"
        else
          output
        end
      end
    end
  end
end
