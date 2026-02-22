# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Tools::ShellExec do
  subject(:tool) { described_class.new(config:) }

  let(:session) { Homunculus::Session.new }
  let(:config) do
    raw = {
      "gateway" => { "host" => "127.0.0.1" },
      "models" => {
        "local" => {
          "provider" => "ollama", "context_window" => 32_768, "temperature" => 0.7
        }
      },
      "agent" => { "workspace_path" => "/tmp/test-workspace" },
      "tools" => {
        "blocked_patterns" => ["rm -rf /", "mkfs", "dd if=", "> /dev/"],
        "sandbox" => {
          "enabled" => true,
          "image" => "homunculus-sandbox:latest",
          "network" => "none",
          "memory_limit" => "512m",
          "cpu_limit" => "1.0",
          "read_only_root" => true,
          "drop_capabilities" => ["ALL"],
          "no_new_privileges" => true
        }
      },
      "memory" => {},
      "security" => {}
    }
    Homunculus::Config.new(raw)
  end

  it "has correct metadata" do
    expect(tool.name).to eq("shell_exec")
    expect(tool.requires_confirmation).to be true
    expect(tool.trust_level).to eq(:untrusted)
  end

  it "has correct parameters" do
    params = tool.json_schema_parameters
    expect(params[:properties]).to have_key("command")
    expect(params[:properties]).to have_key("timeout")
    expect(params[:properties]).to have_key("network")
    expect(params[:properties]).to have_key("workdir")
    expect(params[:required]).to eq(["command"])
  end

  it "fails when command is missing" do
    result = tool.execute(arguments: {}, session:)

    expect(result.success).to be false
    expect(result.error).to include("Missing required parameter: command")
  end

  it "fails when command is empty" do
    result = tool.execute(arguments: { command: "   " }, session:)

    expect(result.success).to be false
    expect(result.error).to include("non-empty string")
  end

  describe "blocked command detection" do
    it "rejects rm -rf /" do
      result = tool.execute(arguments: { command: "rm -rf /" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Blocked command pattern")
    end

    it "rejects mkfs commands" do
      result = tool.execute(arguments: { command: "mkfs.ext4 /dev/sda" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Blocked command pattern")
    end

    it "rejects dd if= commands" do
      result = tool.execute(arguments: { command: "dd if=/dev/zero of=/dev/sda" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Blocked command pattern")
    end

    it "rejects > /dev/ commands" do
      result = tool.execute(arguments: { command: "echo test > /dev/sda" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Blocked command pattern")
    end
  end

  describe "sandbox execution" do
    it "runs command in Docker sandbox and returns output" do
      allow(Open3).to receive(:capture3).and_return(
        ["hello world\n", "", instance_double(Process::Status, exitstatus: 0)]
      )

      result = tool.execute(arguments: { command: "echo hello world" }, session:)

      expect(result.success).to be true
      expect(result.output).to eq("hello world")
      expect(result.metadata[:exit_code]).to eq(0)
    end

    it "builds correct docker command with security options" do
      docker_args = nil
      allow(Open3).to receive(:capture3) do |*args, **_kwargs|
        docker_args = args
        ["", "", instance_double(Process::Status, exitstatus: 0)]
      end

      tool.execute(arguments: { command: "ls" }, session:)

      expect(docker_args).to include("docker", "run", "--rm")
      expect(docker_args).to include("--network", "none")
      expect(docker_args).to include("--memory", "512m")
      expect(docker_args).to include("--read-only")
      expect(docker_args).to include("--cap-drop", "ALL")
      expect(docker_args).to include("--security-opt", "no-new-privileges:true")
      expect(docker_args).to include("homunculus-sandbox:latest")
    end

    it "mounts workspace as read-only" do
      docker_args = nil
      allow(Open3).to receive(:capture3) do |*args, **_kwargs|
        docker_args = args
        ["", "", instance_double(Process::Status, exitstatus: 0)]
      end

      tool.execute(arguments: { command: "ls" }, session:)

      bind_arg = docker_args[docker_args.index("-v") + 1]
      expect(bind_arg).to match(%r{:/workspace:ro$})
    end

    it "enables network when requested" do
      docker_args = nil
      allow(Open3).to receive(:capture3) do |*args, **_kwargs|
        docker_args = args
        ["", "", instance_double(Process::Status, exitstatus: 0)]
      end

      tool.execute(arguments: { command: "curl example.com", network: true }, session:)

      net_index = docker_args.index("--network")
      expect(docker_args[net_index + 1]).to eq("bridge")
    end

    it "disables network by default" do
      docker_args = nil
      allow(Open3).to receive(:capture3) do |*args, **_kwargs|
        docker_args = args
        ["", "", instance_double(Process::Status, exitstatus: 0)]
      end

      tool.execute(arguments: { command: "ls" }, session:)

      net_index = docker_args.index("--network")
      expect(docker_args[net_index + 1]).to eq("none")
    end

    it "returns stderr in metadata" do
      allow(Open3).to receive(:capture3).and_return(
        ["", "warning: something\n", instance_double(Process::Status, exitstatus: 0)]
      )

      result = tool.execute(arguments: { command: "some-cmd" }, session:)

      expect(result.metadata[:stderr]).to eq("warning: something")
    end

    it "returns non-zero exit code" do
      allow(Open3).to receive(:capture3).and_return(
        ["", "not found\n", instance_double(Process::Status, exitstatus: 127)]
      )

      result = tool.execute(arguments: { command: "nonexistent-cmd" }, session:)

      expect(result.success).to be true # Still returns ok with exit code
      expect(result.metadata[:exit_code]).to eq(127)
    end
  end

  describe "timeout handling" do
    it "kills container after timeout" do
      allow(Open3).to receive(:capture3).and_raise(Timeout::Error)

      result = tool.execute(arguments: { command: "sleep 999", timeout: 5 }, session:)

      expect(result.success).to be false
      expect(result.error).to include("timed out")
      expect(result.metadata[:timed_out]).to be true
    end

    it "caps timeout at 120 seconds" do
      timeout_used = nil
      allow(Open3).to receive(:capture3) do |*_args, **kwargs|
        timeout_used = kwargs[:timeout]
        ["", "", instance_double(Process::Status, exitstatus: 0)]
      end

      tool.execute(arguments: { command: "ls", timeout: 9999 }, session:)

      expect(timeout_used).to eq(120)
    end

    it "defaults timeout to 30 seconds" do
      timeout_used = nil
      allow(Open3).to receive(:capture3) do |*_args, **kwargs|
        timeout_used = kwargs[:timeout]
        ["", "", instance_double(Process::Status, exitstatus: 0)]
      end

      tool.execute(arguments: { command: "ls" }, session:)

      expect(timeout_used).to eq(30)
    end
  end

  describe "workdir validation" do
    it "rejects path traversal in workdir" do
      result = tool.execute(arguments: { command: "ls", workdir: "/workspace/../../etc" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Invalid working directory")
    end

    it "accepts valid workdir" do
      allow(Open3).to receive(:capture3).and_return(
        ["", "", instance_double(Process::Status, exitstatus: 0)]
      )

      result = tool.execute(arguments: { command: "ls", workdir: "/workspace/subdir" }, session:)

      expect(result.success).to be true
    end
  end

  describe "local execution (sandbox disabled)" do
    let(:config) do
      raw = {
        "gateway" => { "host" => "127.0.0.1" },
        "models" => {
          "local" => {
            "provider" => "ollama", "context_window" => 32_768, "temperature" => 0.7
          }
        },
        "agent" => { "workspace_path" => "/tmp/test-workspace" },
        "tools" => {
          "blocked_patterns" => [],
          "sandbox" => { "enabled" => false }
        },
        "memory" => {},
        "security" => {}
      }
      Homunculus::Config.new(raw)
    end

    it "executes directly without Docker" do
      allow(Open3).to receive(:capture3).with("/bin/sh", "-c", "echo test", timeout: 30).and_return(
        ["test\n", "", instance_double(Process::Status, exitstatus: 0)]
      )

      result = tool.execute(arguments: { command: "echo test" }, session:)

      expect(result.success).to be true
      expect(result.output).to eq("test")
    end
  end
end
