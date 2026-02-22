# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Homunculus::Skills::Skill do
  let(:tmpdir) { Dir.mktmpdir("skill_test") }

  after { FileUtils.rm_rf(tmpdir) }

  def write_skill(content)
    path = File.join(tmpdir, "SKILL.md")
    File.write(path, content)
    path
  end

  describe ".parse" do
    it "parses YAML frontmatter and markdown body" do
      path = write_skill(<<~SKILL)
        ---
        name: test_skill
        description: "A test skill"
        tools_required: [shell_exec, web_fetch]
        model_preference: local
        auto_activate: true
        triggers: ["test", "check"]
        ---

        # Test Skill

        Do testing things.
      SKILL

      skill = described_class.parse(path)

      expect(skill.name).to eq("test_skill")
      expect(skill.description).to eq("A test skill")
      expect(skill.tools_required).to eq(%w[shell_exec web_fetch])
      expect(skill.model_preference).to eq(:local)
      expect(skill.auto_activate).to be true
      expect(skill.triggers).to eq(%w[test check])
      expect(skill.body).to include("# Test Skill")
      expect(skill.path).to eq(path)
    end

    it "handles missing optional fields with defaults" do
      path = write_skill(<<~SKILL)
        ---
        name: minimal_skill
        ---

        # Minimal
      SKILL

      skill = described_class.parse(path)

      expect(skill.name).to eq("minimal_skill")
      expect(skill.description).to eq("")
      expect(skill.tools_required).to eq([])
      expect(skill.model_preference).to eq(:auto)
      expect(skill.auto_activate).to be false
      expect(skill.triggers).to eq([])
    end

    it "raises for files without frontmatter" do
      path = write_skill("No frontmatter here")

      expect { described_class.parse(path) }.to raise_error(ArgumentError, /must start with YAML frontmatter/)
    end

    it "raises for malformed frontmatter" do
      path = write_skill("---\n---")

      # Empty YAML → nil frontmatter → NoMethodError or KeyError
      expect { described_class.parse(path) }.to raise_error(StandardError)
    end
  end

  describe "Data immutability" do
    it "is frozen by default (Data.define)" do
      path = write_skill(<<~SKILL)
        ---
        name: frozen_test
        triggers: ["test"]
        ---

        # Body
      SKILL

      skill = described_class.parse(path)

      expect(skill).to be_frozen
    end
  end
end
