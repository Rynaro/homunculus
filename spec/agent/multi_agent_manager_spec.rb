# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Homunculus::Agent::MultiAgentManager do
  let(:workspace_dir) { Dir.mktmpdir("workspace") }
  let(:agents_dir) { File.join(workspace_dir, "agents") }
  let(:config) { Homunculus::Config.load("config/default.toml") }
  let(:manager) { described_class.new(workspace_path: workspace_dir, config: config) }

  before do
    FileUtils.mkdir_p(agents_dir)
  end

  after { FileUtils.rm_rf(workspace_dir) }

  def create_agent(name, soul:, tools: nil)
    dir = File.join(agents_dir, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SOUL.md"), soul)
    File.write(File.join(dir, "TOOLS.md"), tools) if tools
  end

  describe "agent loading" do
    it "loads agents from workspace/agents/" do
      create_agent("coder", soul: "You are a coding specialist.")
      create_agent("researcher", soul: "You are a research specialist.")

      mgr = described_class.new(workspace_path: workspace_dir, config: config)

      expect(mgr.size).to be >= 2 # coder, researcher + auto-created default
      expect(mgr.agent_exists?(:coder)).to be true
      expect(mgr.agent_exists?(:researcher)).to be true
    end

    it "always creates a default agent" do
      mgr = described_class.new(workspace_path: workspace_dir, config: config)

      expect(mgr.agent_exists?(:default)).to be true
    end

    it "skips directories without SOUL.md" do
      FileUtils.mkdir_p(File.join(agents_dir, "empty"))

      mgr = described_class.new(workspace_path: workspace_dir, config: config)

      expect(mgr.agent_exists?(:empty)).to be false
    end

    it "loads TOOLS.md when present" do
      create_agent("home",
                   soul: "You are a home automation specialist.",
                   tools: "## Allowed Tools\n- `mqtt_subscribe`\n- `mqtt_publish`")

      mgr = described_class.new(workspace_path: workspace_dir, config: config)

      defn = mgr.agent_definition(:home)
      expect(defn.tools_config).to include("mqtt_subscribe")
      expect(defn.allowed_tools).to include("mqtt_subscribe", "mqtt_publish")
    end
  end

  describe "#detect_agent" do
    before do
      create_agent("coder", soul: "You are a coding specialist.")
      create_agent("home", soul: "You are a home automation specialist.")
      create_agent("researcher", soul: "You are a research specialist.")
    end

    let(:mgr) { described_class.new(workspace_path: workspace_dir, config: config) }

    context "with @mention" do
      it "routes @coder to coder agent" do
        agent, message = mgr.detect_agent("@coder fix this bug please")

        expect(agent).to eq(:coder)
        expect(message).to eq("fix this bug please")
      end

      it "routes @home to home agent" do
        agent, _message = mgr.detect_agent("@home check the sensors")

        expect(agent).to eq(:home)
      end

      it "falls back to content analysis for unknown @mentions" do
        _, message = mgr.detect_agent("@unknown do something")

        expect(message).to eq("@unknown do something")
      end
    end

    context "with content-based routing" do
      it "routes code questions to coder" do
        agent, = mgr.detect_agent("implement a sorting algorithm")

        expect(agent).to eq(:coder)
      end

      it "routes mqtt questions to home" do
        agent, = mgr.detect_agent("check the mqtt sensor readings")

        expect(agent).to eq(:home)
      end

      it "routes research questions to researcher" do
        agent, = mgr.detect_agent("research the best approach for this")

        expect(agent).to eq(:researcher)
      end

      it "routes unclassified messages to default" do
        agent, = mgr.detect_agent("hello, how are you?")

        expect(agent).to eq(:default)
      end
    end
  end

  describe "#list_agents" do
    before do
      create_agent("coder", soul: "# Coder\nYou are a coding specialist.")
      create_agent("home", soul: "# Home\nYou are a home automation specialist.")
    end

    let(:mgr) { described_class.new(workspace_path: workspace_dir, config: config) }

    it "returns agent info for all loaded agents" do
      agents = mgr.list_agents

      names = agents.map { |a| a[:name] }
      expect(names).to include("coder", "home", "default")
    end

    it "includes description extracted from SOUL.md" do
      agents = mgr.list_agents
      coder = agents.find { |a| a[:name] == "coder" }

      expect(coder[:description]).to include("coding specialist")
    end
  end

  describe "#agent_definition" do
    before do
      create_agent("coder", soul: "You are a coding specialist.\n\n## Model Preference\nPrefer Claude for code.")
    end

    let(:mgr) { described_class.new(workspace_path: workspace_dir, config: config) }

    it "returns the definition for a known agent" do
      defn = mgr.agent_definition(:coder)

      expect(defn).not_to be_nil
      expect(defn.name).to eq("coder")
      expect(defn.soul).to include("coding specialist")
    end

    it "returns nil for unknown agents" do
      defn = mgr.agent_definition(:nonexistent)

      expect(defn).to be_nil
    end

    it "extracts model preference from SOUL.md" do
      defn = mgr.agent_definition(:coder)

      expect(defn.model_preference).to eq(:escalation)
    end
  end

  describe "Ractor isolation" do
    it "detects Ractor::Port availability" do
      # Just verify the check doesn't crash
      mgr = described_class.new(workspace_path: workspace_dir, config: config)
      expect(mgr.size).to be >= 1
    end
  end
end
