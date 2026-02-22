# frozen_string_literal: true

require "English"
require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Homunculus::Skills::Loader do
  let(:skills_dir) { Dir.mktmpdir("skills") }
  let(:loader) { described_class.new(skills_dir: skills_dir) }

  after { FileUtils.rm_rf(skills_dir) }

  def create_skill(name, frontmatter:, body:)
    dir = File.join(skills_dir, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SKILL.md"), <<~SKILL)
      ---
      #{frontmatter}
      ---

      #{body}
    SKILL
  end

  describe "#load_all" do
    it "loads skills from directory" do
      create_skill("git_workflow",
                   frontmatter: <<~YAML.chomp,
                     name: git_workflow
                     description: "Git operations"
                     triggers: ["git", "commit", "branch"]
                     auto_activate: false
                   YAML
                   body: "# Git Workflow\nUse conventional commits.")

      loader.reload!

      expect(loader.size).to eq(1)
      expect(loader["git_workflow"]).not_to be_nil
      expect(loader["git_workflow"].name).to eq("git_workflow")
      expect(loader["git_workflow"].triggers).to eq(%w[git commit branch])
      expect(loader["git_workflow"].auto_activate).to be false
    end

    it "loads multiple skills" do
      create_skill("skill_a",
                   frontmatter: "name: skill_a\ndescription: \"A\"\ntriggers: [\"alpha\"]",
                   body: "# A")
      create_skill("skill_b",
                   frontmatter: "name: skill_b\ndescription: \"B\"\ntriggers: [\"beta\"]",
                   body: "# B")

      loader.reload!

      expect(loader.size).to eq(2)
    end

    it "skips directories without SKILL.md" do
      FileUtils.mkdir_p(File.join(skills_dir, "empty_dir"))

      loader.reload!

      expect(loader.size).to eq(0)
    end

    it "skips skills with invalid frontmatter" do
      dir = File.join(skills_dir, "bad")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"), "No frontmatter here")

      loader.reload!

      expect(loader.size).to eq(0)
    end
  end

  describe "#match_skills" do
    before do
      create_skill("git_workflow",
                   frontmatter: <<~YAML.chomp,
                     name: git_workflow
                     description: "Git operations"
                     triggers: ["git", "commit", "branch"]
                     auto_activate: false
                   YAML
                   body: "# Git")

      create_skill("home_monitor",
                   frontmatter: <<~YAML.chomp,
                     name: home_monitor
                     description: "Home sensor monitor"
                     triggers: ["sensor", "humidity", "temperature"]
                     auto_activate: true
                   YAML
                   body: "# Home Monitor")

      loader.reload!
    end

    it "matches skills by trigger keywords" do
      matched = loader.match_skills(message: "git commit my changes")

      expect(matched.size).to eq(1)
      expect(matched.first.name).to eq("git_workflow")
    end

    it "matches case-insensitively" do
      matched = loader.match_skills(message: "Check the HUMIDITY sensor")

      expect(matched.size).to eq(1)
      expect(matched.first.name).to eq("home_monitor")
    end

    it "returns empty when no triggers match" do
      matched = loader.match_skills(message: "What is the weather like?")

      expect(matched).to be_empty
    end

    it "returns multiple matching skills sorted by relevance" do
      # Both skills shouldn't match for this message
      matched = loader.match_skills(message: "git commit and check humidity")

      expect(matched.size).to eq(2)
    end

    it "filters by enabled skills when provided" do
      matched = loader.match_skills(
        message: "git commit and check humidity",
        enabled_skills: Set.new(["git_workflow"])
      )

      expect(matched.size).to eq(1)
      expect(matched.first.name).to eq("git_workflow")
    end
  end

  describe "#auto_activated" do
    before do
      create_skill("auto_skill",
                   frontmatter: <<~YAML.chomp,
                     name: auto_skill
                     description: "Auto"
                     triggers: ["test"]
                     auto_activate: true
                   YAML
                   body: "# Auto")

      create_skill("manual_skill",
                   frontmatter: <<~YAML.chomp,
                     name: manual_skill
                     description: "Manual"
                     triggers: ["manual"]
                     auto_activate: false
                   YAML
                   body: "# Manual")

      loader.reload!
    end

    it "returns only auto-activated skills" do
      auto = loader.auto_activated

      expect(auto.size).to eq(1)
      expect(auto.first.name).to eq("auto_skill")
    end
  end

  describe "#inject_skill_context" do
    before do
      create_skill("test_skill",
                   frontmatter: <<~YAML.chomp,
                     name: test_skill
                     description: "Test skill"
                     triggers: ["test"]
                     auto_activate: false
                   YAML
                   body: "# Test Skill\nDo testing stuff.")

      loader.reload!
    end

    it "injects skill XML into system prompt" do
      skill = loader["test_skill"]
      result = loader.inject_skill_context(
        skills: [skill],
        system_prompt: "You are a helpful assistant."
      )

      expect(result).to include("You are a helpful assistant.")
      expect(result).to include("<active_skills>")
      expect(result).to include('<skill name="test_skill"')
      expect(result).to include("# Test Skill")
      expect(result).to include("</active_skills>")
    end

    it "returns prompt unchanged when no skills provided" do
      result = loader.inject_skill_context(skills: [], system_prompt: "Base prompt")

      expect(result).to eq("Base prompt")
    end
  end

  describe "#validate_tools" do
    before do
      create_skill("needs_tools",
                   frontmatter: <<~YAML.chomp,
                     name: needs_tools
                     description: "Needs tools"
                     tools_required: [shell_exec, web_fetch, nonexistent_tool]
                     triggers: ["test"]
                     auto_activate: false
                   YAML
                   body: "# Needs Tools")

      loader.reload!
    end

    it "returns missing tools" do
      registry = instance_double(Homunculus::Tools::Registry,
                                 tool_names: %w[shell_exec web_fetch echo])

      skill = loader["needs_tools"]
      missing = loader.validate_tools(skill, registry)

      expect(missing).to eq(["nonexistent_tool"])
    end

    it "returns empty when all tools present" do
      registry = instance_double(Homunculus::Tools::Registry,
                                 tool_names: %w[shell_exec web_fetch nonexistent_tool])

      skill = loader["needs_tools"]
      missing = loader.validate_tools(skill, registry)

      expect(missing).to be_empty
    end
  end

  context "with non-existent directory" do
    let(:loader) { described_class.new(skills_dir: "/tmp/nonexistent_skills_dir_#{$PROCESS_ID}") }

    it "initializes with zero skills" do
      expect(loader.size).to eq(0)
    end
  end
end
