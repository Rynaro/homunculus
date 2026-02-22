# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "Starter tools" do
  let(:session) { Homunculus::Session.new }

  describe Homunculus::Tools::Echo do
    subject(:tool) { described_class.new }

    it "has correct metadata" do
      expect(tool.name).to eq("echo")
      expect(tool.requires_confirmation).to be false
      expect(tool.trust_level).to eq(:trusted)
    end

    it "echoes the input text" do
      result = tool.execute(arguments: { text: "hello world" }, session:)

      expect(result.success).to be true
      expect(result.output).to eq("hello world")
    end

    it "fails when text is missing" do
      result = tool.execute(arguments: {}, session:)

      expect(result.success).to be false
      expect(result.error).to include("Missing required parameter")
    end
  end

  describe Homunculus::Tools::DatetimeNow do
    subject(:tool) { described_class.new }

    it "has correct metadata" do
      expect(tool.name).to eq("datetime_now")
      expect(tool.requires_confirmation).to be false
    end

    it "returns the current date and time" do
      result = tool.execute(arguments: {}, session:)

      expect(result.success).to be true
      expect(result.output).to match(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/)
    end
  end

  describe Homunculus::Tools::WorkspaceRead do
    subject(:tool) { described_class.new }

    let(:workspace_dir) { Dir.mktmpdir("workspace_test") }

    before do
      # Create test files in a temporary workspace
      File.write(File.join(workspace_dir, "test.txt"), "Hello, world!")
      allow(tool).to receive(:resolve_workspace).and_return(workspace_dir)
    end

    after { FileUtils.rm_rf(workspace_dir) }

    it "has correct metadata" do
      expect(tool.name).to eq("workspace_read")
      expect(tool.requires_confirmation).to be false
    end

    it "reads a file from workspace" do
      result = tool.execute(arguments: { path: "test.txt" }, session:)

      expect(result.success).to be true
      expect(result.output).to eq("Hello, world!")
    end

    it "fails for nonexistent files" do
      result = tool.execute(arguments: { path: "nonexistent.txt" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("File not found")
    end

    it "rejects path traversal attacks" do
      result = tool.execute(arguments: { path: "../../../etc/passwd" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Access denied")
    end

    it "rejects absolute paths outside workspace" do
      result = tool.execute(arguments: { path: "/etc/passwd" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Access denied")
    end

    it "fails when path is missing" do
      result = tool.execute(arguments: {}, session:)

      expect(result.success).to be false
      expect(result.error).to include("Missing required parameter")
    end
  end

  describe Homunculus::Tools::WorkspaceWrite do
    subject(:tool) { described_class.new }

    let(:workspace_dir) { Dir.mktmpdir("workspace_test") }

    before do
      allow(tool).to receive(:resolve_workspace).and_return(workspace_dir)
    end

    after { FileUtils.rm_rf(workspace_dir) }

    it "has correct metadata" do
      expect(tool.name).to eq("workspace_write")
      expect(tool.requires_confirmation).to be true
      expect(tool.trust_level).to eq(:mixed)
    end

    it "writes content to a file" do
      result = tool.execute(arguments: { path: "output.txt", content: "test content" }, session:)

      expect(result.success).to be true
      expect(File.read(File.join(workspace_dir, "output.txt"))).to eq("test content")
    end

    it "creates parent directories" do
      result = tool.execute(arguments: { path: "deep/nested/file.txt", content: "nested" }, session:)

      expect(result.success).to be true
      expect(File.read(File.join(workspace_dir, "deep/nested/file.txt"))).to eq("nested")
    end

    it "supports append mode" do
      tool.execute(arguments: { path: "log.txt", content: "line1\n" }, session:)
      tool.execute(arguments: { path: "log.txt", content: "line2\n", mode: "append" }, session:)

      content = File.read(File.join(workspace_dir, "log.txt"))
      expect(content).to eq("line1\nline2\n")
    end

    it "rejects path traversal attacks" do
      result = tool.execute(arguments: { path: "../../../tmp/evil.txt", content: "bad" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Access denied")
    end

    it "fails when content is missing" do
      result = tool.execute(arguments: { path: "test.txt" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Missing required parameter")
    end
  end

  describe Homunculus::Tools::WorkspaceList do
    subject(:tool) { described_class.new }

    let(:workspace_dir) { Dir.mktmpdir("workspace_test") }

    before do
      File.write(File.join(workspace_dir, "file1.txt"), "content")
      File.write(File.join(workspace_dir, "file2.md"), "content")
      FileUtils.mkdir_p(File.join(workspace_dir, "subdir"))
      File.write(File.join(workspace_dir, "subdir", "nested.txt"), "content")
      allow(tool).to receive(:resolve_workspace).and_return(workspace_dir)
    end

    after { FileUtils.rm_rf(workspace_dir) }

    it "has correct metadata" do
      expect(tool.name).to eq("workspace_list")
      expect(tool.requires_confirmation).to be false
    end

    it "lists files in workspace root" do
      result = tool.execute(arguments: {}, session:)

      expect(result.success).to be true
      expect(result.output).to include("file1.txt")
      expect(result.output).to include("file2.md")
      expect(result.output).to include("subdir/")
    end

    it "lists files in a subdirectory" do
      result = tool.execute(arguments: { path: "subdir" }, session:)

      expect(result.success).to be true
      expect(result.output).to include("nested.txt")
    end

    it "rejects path traversal attacks" do
      result = tool.execute(arguments: { path: "../../../etc" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Access denied")
    end
  end
end
