# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Homunculus::Tools::PathValidation do
  # Create a test class that includes the module
  subject(:validator) { validator_class.new }

  let(:validator_class) do
    Class.new do
      include Homunculus::Tools::PathValidation
    end
  end
  let(:workspace_dir) { Dir.mktmpdir("workspace_test") }

  before do
    # Create test structure
    FileUtils.mkdir_p(File.join(workspace_dir, "subdir"))
    File.write(File.join(workspace_dir, "test.txt"), "content")
    File.write(File.join(workspace_dir, "subdir", "nested.txt"), "nested content")
  end

  after { FileUtils.rm_rf(workspace_dir) }

  describe "#validate_path!" do
    it "resolves a relative path within workspace" do
      result = validator.validate_path!("test.txt", workspace: workspace_dir)

      expect(result.to_s).to eq(File.join(File.realpath(workspace_dir), "test.txt"))
    end

    it "resolves nested paths" do
      result = validator.validate_path!("subdir/nested.txt", workspace: workspace_dir)

      expect(result.to_s).to eq(File.join(File.realpath(workspace_dir), "subdir", "nested.txt"))
    end

    it "resolves the workspace root itself" do
      result = validator.validate_path!(".", workspace: workspace_dir)

      expect(result.to_s).to eq(File.realpath(workspace_dir))
    end

    it "rejects path traversal with ../" do
      expect do
        validator.validate_path!("../../../etc/passwd", workspace: workspace_dir)
      end.to raise_error(SecurityError, /escapes workspace boundary/)
    end

    it "rejects absolute paths outside workspace" do
      expect do
        validator.validate_path!("/etc/passwd", workspace: workspace_dir)
      end.to raise_error(SecurityError, /escapes workspace boundary/)
    end

    it "rejects paths with embedded traversal" do
      expect do
        validator.validate_path!("subdir/../../etc/passwd", workspace: workspace_dir)
      end.to raise_error(SecurityError, /escapes workspace boundary/)
    end

    context "with symlinks" do
      before do
        # Create a symlink pointing outside workspace
        target = File.join(Dir.tmpdir, "symlink_target_#{SecureRandom.hex(4)}.txt")
        File.write(target, "external content")
        @external_file = target
        File.symlink(target, File.join(workspace_dir, "escape_link.txt"))
      end

      after { FileUtils.rm_f(@external_file) }

      it "rejects symlinks that escape workspace" do
        expect do
          validator.validate_path!("escape_link.txt", workspace: workspace_dir)
        end.to raise_error(SecurityError, /escapes workspace boundary/)
      end
    end
  end

  describe "#sanitize_path!" do
    it "accepts normal paths" do
      result = validator.sanitize_path!("subdir/file.txt")
      expect(result).to eq("subdir/file.txt")
    end

    it "rejects paths with null bytes" do
      expect do
        validator.sanitize_path!("test.txt\0.evil")
      end.to raise_error(SecurityError, /null bytes/)
    end

    it "rejects empty paths" do
      expect do
        validator.sanitize_path!("")
      end.to raise_error(SecurityError, /empty/)
    end

    it "rejects nil paths" do
      expect do
        validator.sanitize_path!(nil)
      end.to raise_error(SecurityError, /empty/)
    end

    it "rejects whitespace-only paths" do
      expect do
        validator.sanitize_path!("   ")
      end.to raise_error(SecurityError, /empty/)
    end
  end
end
