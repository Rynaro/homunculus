# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "json"

RSpec.describe Homunculus::Security::AuditLogger do
  subject(:audit) { described_class.new(tmpfile.path) }

  let(:tmpfile) { Tempfile.new(["audit", ".jsonl"]) }

  after do
    tmpfile.close
    tmpfile.unlink
  end

  describe "#log" do
    it "writes valid JSONL entries" do
      audit.log(
        action: "tool_exec",
        session_id: "test-session-123",
        tool: "echo",
        model: "qwen2.5:14b"
      )

      lines = File.readlines(tmpfile.path)
      expect(lines.length).to eq(1)

      entry = JSON.parse(lines.first)
      expect(entry["action"]).to eq("tool_exec")
      expect(entry["session_id"]).to eq("test-session-123")
      expect(entry["tool"]).to eq("echo")
      expect(entry["model"]).to eq("qwen2.5:14b")
      expect(entry["ts"]).to match(/\d{4}-\d{2}-\d{2}T/)
    end

    it "appends multiple entries" do
      3.times do |i|
        audit.log(action: "test_#{i}", session_id: "s-#{i}")
      end

      lines = File.readlines(tmpfile.path)
      expect(lines.length).to eq(3)

      lines.each do |line|
        expect { JSON.parse(line) }.not_to raise_error
      end
    end

    it "omits nil fields" do
      audit.log(action: "simple_action")

      entry = JSON.parse(File.readlines(tmpfile.path).first)
      expect(entry).not_to have_key("session_id")
      expect(entry["action"]).to eq("simple_action")
    end

    it "is thread-safe" do
      threads = 10.times.map do |i|
        Thread.new { audit.log(action: "concurrent_#{i}") }
      end
      threads.each(&:join)

      lines = File.readlines(tmpfile.path)
      expect(lines.length).to eq(10)

      lines.each do |line|
        expect { JSON.parse(line) }.not_to raise_error
      end
    end
  end

  describe "#log_tool_exec" do
    it "logs tool execution with hashed input/output" do
      tool_call = Homunculus::Agent::ModelProvider::ToolCall.new(
        id: "tc-1", name: "echo", arguments: { text: "hello" }
      )
      result = Homunculus::Tools::Result.ok("hello")

      audit.log_tool_exec(
        tool_call:,
        result:,
        session_id: "s-123",
        model: "qwen2.5:14b",
        confirmed: false,
        duration_ms: 42
      )

      entry = JSON.parse(File.readlines(tmpfile.path).first)
      expect(entry["action"]).to eq("tool_exec")
      expect(entry["tool"]).to eq("echo")
      expect(entry["session_id"]).to eq("s-123")
      expect(entry["input_hash"]).not_to eq('{"text":"hello"}')
      expect(entry["input_hash"].length).to eq(16)
      expect(entry["duration_ms"]).to eq(42)
    end
  end
end

# Keep backward-compat test for the old Audit module
RSpec.describe Homunculus::Security::Audit do
  let(:tmpfile) { Tempfile.new(["audit", ".jsonl"]) }

  before { described_class.log_path = tmpfile.path }

  after do
    described_class.reset!
    tmpfile.close
    tmpfile.unlink
  end

  describe ".log" do
    it "writes valid JSONL entries (backward compat)" do
      described_class.log(
        action_type: "tool_call",
        session_id: "test-session",
        tool_name: "echo",
        input: "hello",
        model_used: "qwen2.5:14b"
      )

      lines = File.readlines(tmpfile.path)
      expect(lines.length).to eq(1)

      entry = JSON.parse(lines.first)
      expect(entry["action_type"]).to eq("tool_call")
      expect(entry["session_id"]).to eq("test-session")
    end
  end
end
