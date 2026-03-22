# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Homunculus::Agent::Warmup do
  let(:config) { Homunculus::Config.load("config/default.toml") }
  let(:workspace_dir) { Dir.mktmpdir("warmup-test") }

  let(:ollama_provider) do
    instance_double(Homunculus::Agent::Models::OllamaProvider,
                    preload_model: { loaded: true, elapsed_ms: 50, load_duration_ns: 100_000 })
  end

  let(:embedder) do
    instance_double(Homunculus::Memory::Embedder, embed: [0.1, 0.2, 0.3])
  end

  let(:warmup) do
    described_class.new(
      ollama_provider: ollama_provider,
      embedder: embedder,
      config: config,
      workspace_path: workspace_dir
    )
  end

  before do
    %w[SOUL.md AGENTS.md USER.md MEMORY.md].each do |f|
      File.write(File.join(workspace_dir, f), "# #{f}\nTest content for #{f}")
    end
  end

  after { FileUtils.remove_entry(workspace_dir) }

  describe "#start! with all providers available" do
    it "runs all steps and transitions to ready" do
      warmup.start!
      warmup.wait!

      expect(warmup).to be_ready
      expect(warmup.results.keys).to contain_exactly(
        :preload_chat_model, :preload_embedding_model, :preread_workspace_files
      )

      warmup.results.each_value do |result|
        expect(result[:status]).to eq(:ok)
        expect(result[:elapsed_ms]).to be_a(Integer)
      end
    end

    it "calls preload_model on the ollama provider" do
      warmup.start!
      warmup.wait!

      expect(ollama_provider).to have_received(:preload_model).with("qwen2.5:14b")
    end

    it "calls embed on the embedder" do
      warmup.start!
      warmup.wait!

      expect(embedder).to have_received(:embed).with("warmup")
    end

    it "reports total elapsed_ms" do
      warmup.start!
      warmup.wait!

      expect(warmup.elapsed_ms).to be_a(Integer).and be >= 0
    end
  end

  describe "steps skipped when config flags are false" do
    let(:config) do
      raw = TomlRB.load_file("config/default.toml")
      raw["agent"] ||= {}
      raw["agent"]["warmup"] = {
        "enabled" => true,
        "preload_chat_model" => false,
        "preload_embedding_model" => false,
        "preread_workspace_files" => false
      }
      Homunculus::Config.new(raw)
    end

    it "skips all steps and still becomes ready" do
      warmup.start!
      warmup.wait!

      expect(warmup).to be_ready
      warmup.results.each_value do |result|
        expect(result[:status]).to eq(:skipped)
      end
    end

    it "does not call providers" do
      warmup.start!
      warmup.wait!

      expect(ollama_provider).not_to have_received(:preload_model)
      expect(embedder).not_to have_received(:embed)
    end
  end

  describe "steps skipped when providers are nil" do
    let(:warmup) do
      described_class.new(
        ollama_provider: nil,
        embedder: nil,
        config: config,
        workspace_path: workspace_dir
      )
    end

    it "skips model steps but runs workspace preread" do
      warmup.start!
      warmup.wait!

      expect(warmup).to be_ready
      expect(warmup.results[:preload_chat_model][:status]).to eq(:skipped)
      expect(warmup.results[:preload_embedding_model][:status]).to eq(:skipped)
      expect(warmup.results[:preread_workspace_files][:status]).to eq(:ok)
    end
  end

  describe "failure isolation" do
    let(:ollama_provider) do
      instance_double(Homunculus::Agent::Models::OllamaProvider).tap do |p|
        allow(p).to receive(:preload_model).and_raise(StandardError, "connection refused")
      end
    end

    let(:embedder) do
      instance_double(Homunculus::Memory::Embedder).tap do |e|
        allow(e).to receive(:embed).and_raise(StandardError, "embedding timeout")
      end
    end

    it "marks failed steps but still completes all steps" do
      warmup.start!
      warmup.wait!

      expect(warmup).to be_ready
      expect(warmup.results[:preload_chat_model][:status]).to eq(:failed)
      expect(warmup.results[:preload_chat_model][:error]).to eq("connection refused")
      expect(warmup.results[:preload_embedding_model][:status]).to eq(:failed)
      expect(warmup.results[:preload_embedding_model][:error]).to eq("embedding timeout")
      expect(warmup.results[:preread_workspace_files][:status]).to eq(:ok)
    end
  end

  describe "#ready?" do
    it "returns false before start" do
      expect(warmup).not_to be_ready
    end

    it "returns true after completion" do
      warmup.start!
      warmup.wait!

      expect(warmup).to be_ready
    end
  end

  describe "#wait!" do
    it "blocks until warmup is complete" do
      warmup.start!
      warmup.wait!

      expect(warmup).to be_ready
      expect(warmup.results).not_to be_empty
    end
  end

  describe "callback events" do
    it "receives events in correct order" do
      events = []
      callback = proc { |event, step, detail| events << [event, step, detail] }

      warmup.start!(callback: callback)
      warmup.wait!

      done_events, step_events = events.partition { |e, _, _| e == :done }

      expect(done_events.size).to eq(1)
      expect(done_events.first[2]).to include(:elapsed_ms, :results)

      described_class::STEPS.each do |step|
        step_sequence = step_events.select { |_, s, _| s == step }.map(&:first)
        expect(step_sequence).to eq(%i[start complete])
      end
    end

    it "receives :skip events for disabled steps" do
      events = []
      callback = proc { |event, step, detail| events << [event, step, detail] }

      nil_warmup = described_class.new(
        ollama_provider: nil,
        embedder: nil,
        config: config,
        workspace_path: workspace_dir
      )

      nil_warmup.start!(callback: callback)
      nil_warmup.wait!

      skip_steps = events.select { |e, _, _| e == :skip }.map { |_, s, _| s }
      expect(skip_steps).to contain_exactly(:preload_chat_model, :preload_embedding_model)
    end

    it "receives :fail events for failing steps" do
      failing_provider = instance_double(Homunculus::Agent::Models::OllamaProvider)
      allow(failing_provider).to receive(:preload_model).and_raise(StandardError, "boom")

      events = []
      callback = proc { |event, step, detail| events << [event, step, detail] }

      fail_warmup = described_class.new(
        ollama_provider: failing_provider,
        embedder: embedder,
        config: config,
        workspace_path: workspace_dir
      )

      fail_warmup.start!(callback: callback)
      fail_warmup.wait!

      fail_events = events.select { |e, _, _| e == :fail }
      expect(fail_events.size).to eq(1)
      expect(fail_events.first[1]).to eq(:preload_chat_model)
      expect(fail_events.first[2][:error]).to eq("boom")
    end
  end

  describe "results hash" do
    it "contains per-step status with expected keys" do
      warmup.start!
      warmup.wait!

      described_class::STEPS.each do |step|
        result = warmup.results[step]
        expect(result).to include(status: :ok)
        expect(result[:elapsed_ms]).to be_a(Integer)
        expect(result).not_to have_key(:error)
      end
    end
  end

  describe "warmup entirely disabled" do
    let(:config) do
      raw = TomlRB.load_file("config/default.toml")
      raw["agent"] ||= {}
      raw["agent"]["warmup"] = {
        "enabled" => false,
        "preload_chat_model" => true,
        "preload_embedding_model" => true,
        "preread_workspace_files" => true
      }
      Homunculus::Config.new(raw)
    end

    it "skips all steps immediately and becomes ready" do
      warmup.start!

      expect(warmup).to be_ready
      warmup.results.each_value do |result|
        expect(result[:status]).to eq(:skipped)
      end
    end

    it "does not spawn a background thread" do
      expect(Thread).not_to receive(:new)

      warmup.start!
    end

    it "does not call any providers" do
      warmup.start!

      expect(ollama_provider).not_to have_received(:preload_model)
      expect(embedder).not_to have_received(:embed)
    end

    it "fires :done callback with zero elapsed" do
      events = []
      callback = proc { |event, step, detail| events << [event, step, detail] }

      warmup.start!(callback: callback)

      done_events = events.select { |e, _, _| e == :done }
      expect(done_events.size).to eq(1)
      expect(done_events.first[2][:elapsed_ms]).to eq(0)
    end
  end
end
