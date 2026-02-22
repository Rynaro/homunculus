# frozen_string_literal: true

require "spec_helper"
require "toml-rb"

RSpec.describe Homunculus::Agent::Models::Router do
  let(:models_config) { TomlRB.load_file("config/models.toml.example") }
  let(:mock_ollama) { instance_double(Homunculus::Agent::Models::OllamaProvider, name: :ollama) }
  let(:mock_anthropic) { instance_double(Homunculus::Agent::Models::AnthropicProvider, name: :anthropic) }
  let(:providers) { { ollama: mock_ollama, anthropic: mock_anthropic } }
  let(:tracker) { instance_double(Homunculus::Agent::Models::UsageTracker, monthly_cloud_spend_usd: 0.0) }

  let(:router) do
    described_class.new(config: models_config, providers: providers, usage_tracker: tracker)
  end

  let(:messages) { [{ role: "user", content: "Hello" }] }

  def stub_ollama_generate(content: "Hello! How can I help you today?", tool_calls: [], finish_reason: :stop)
    allow(mock_ollama).to receive(:generate).and_return({
                                                          content: content,
                                                          tool_calls: tool_calls,
                                                          model: "homunculus-workhorse",
                                                          usage: { prompt_tokens: 100, completion_tokens: 50, total_tokens: 150 },
                                                          finish_reason: finish_reason,
                                                          cost_usd: 0.0,
                                                          metadata: {}
                                                        })
  end

  def stub_anthropic_generate(content: "Cloud response", tool_calls: [], finish_reason: :stop)
    allow(mock_anthropic).to receive(:generate).and_return({
                                                             content: content,
                                                             tool_calls: tool_calls,
                                                             model: "claude-haiku-4-5-20251001",
                                                             usage: { prompt_tokens: 200, completion_tokens: 100,
                                                                      total_tokens: 300 },
                                                             finish_reason: finish_reason,
                                                             cost_usd: 0.001,
                                                             metadata: {}
                                                           })
  end

  describe "#resolve_tier" do
    context "with explicit tier override" do
      it "returns the overridden tier" do
        tier = router.resolve_tier(tier: :coder)
        expect(tier).to eq(:coder)
      end

      it "converts string tier to symbol" do
        tier = router.resolve_tier(tier: "thinker")
        expect(tier).to eq(:thinker)
      end
    end

    context "with skill-based routing" do
      it "maps code_review to coder" do
        tier = router.resolve_tier(skill_name: "code_review")
        expect(tier).to eq(:coder)
      end

      it "maps daily_journal to workhorse" do
        tier = router.resolve_tier(skill_name: "daily_journal")
        expect(tier).to eq(:workhorse)
      end

      it "maps home_monitor to whisper" do
        tier = router.resolve_tier(skill_name: "home_monitor")
        expect(tier).to eq(:whisper)
      end

      it "maps deep_research to thinker" do
        tier = router.resolve_tier(skill_name: "deep_research")
        expect(tier).to eq(:thinker)
      end

      it "maps git_workflow to coder" do
        tier = router.resolve_tier(skill_name: "git_workflow")
        expect(tier).to eq(:coder)
      end
    end

    context "with keyword signal detection" do
      it "detects 'debug' as coder" do
        tier = router.resolve_tier(user_message: "debug this Ruby code")
        expect(tier).to eq(:coder)
      end

      it "detects 'refactor' as coder" do
        tier = router.resolve_tier(user_message: "Please refactor this module")
        expect(tier).to eq(:coder)
      end

      it "detects 'analyze' as thinker" do
        tier = router.resolve_tier(user_message: "Can you analyze this data?")
        expect(tier).to eq(:thinker)
      end

      it "detects 'architecture' as thinker" do
        tier = router.resolve_tier(user_message: "What architecture should I use?")
        expect(tier).to eq(:thinker)
      end

      it "detects 'docker' as coder" do
        tier = router.resolve_tier(user_message: "help me with docker compose")
        expect(tier).to eq(:coder)
      end
    end

    context "with no signals" do
      it "defaults to workhorse" do
        tier = router.resolve_tier
        expect(tier).to eq(:workhorse)
      end

      it "defaults to workhorse for empty message" do
        tier = router.resolve_tier(user_message: "")
        expect(tier).to eq(:workhorse)
      end

      it "defaults to workhorse for unknown skill" do
        tier = router.resolve_tier(skill_name: "nonexistent_skill")
        expect(tier).to eq(:workhorse)
      end
    end

    context "priority ordering" do
      it "explicit tier takes priority over skill" do
        tier = router.resolve_tier(tier: :whisper, skill_name: "code_review")
        expect(tier).to eq(:whisper)
      end

      it "skill takes priority over keywords" do
        tier = router.resolve_tier(skill_name: "daily_journal", user_message: "debug this")
        expect(tier).to eq(:workhorse)
      end
    end
  end

  describe "#generate" do
    before do
      allow(tracker).to receive(:record)
    end

    context "happy path: skill routes to correct tier" do
      it "routes code_review to coder tier and returns a Response" do
        allow(mock_ollama).to receive(:generate).and_return({
                                                              content: "Here's the code fix.",
                                                              tool_calls: [],
                                                              model: "homunculus-coder",
                                                              usage: { prompt_tokens: 200, completion_tokens: 100,
                                                                       total_tokens: 300 },
                                                              finish_reason: :stop,
                                                              cost_usd: 0.0,
                                                              metadata: {}
                                                            })

        response = router.generate(messages: messages, skill_name: "code_review")

        expect(response).to be_a(Homunculus::Agent::Models::Response)
        expect(response.tier).to eq(:coder)
        expect(response.provider).to eq(:ollama)
        expect(response.content).to eq("Here's the code fix.")
        expect(response.cost_usd).to eq(0.0)
        expect(response.local?).to be true
        expect(response.cloud?).to be false
      end
    end

    context "escalation: local failure triggers cloud fallback" do
      it "escalates to cloud after max retries" do
        allow(mock_ollama).to receive(:generate)
          .and_raise(Homunculus::Agent::Models::ProviderError, "connection refused")
        stub_anthropic_generate

        response = router.generate(messages: messages)

        expect(response.provider).to eq(:anthropic)
        expect(response.cloud?).to be true
        expect(response.escalated?).to be true
        expect(response.escalated_from).to eq(:workhorse)
      end
    end

    context "budget exceeded: falls back to local thinker" do
      it "redirects to thinker when cloud budget is exceeded" do
        allow(tracker).to receive(:monthly_cloud_spend_usd).and_return(30.0)

        allow(mock_ollama).to receive(:generate).and_return({
                                                              content: "Deep thought response.",
                                                              tool_calls: [],
                                                              model: "homunculus-thinker",
                                                              usage: { prompt_tokens: 100, completion_tokens: 50,
                                                                       total_tokens: 150 },
                                                              finish_reason: :stop,
                                                              cost_usd: 0.0,
                                                              metadata: {}
                                                            })

        response = router.generate(messages: messages, tier: :cloud_standard)

        expect(response.tier).to eq(:thinker)
        expect(response.provider).to eq(:ollama)
        expect(response.local?).to be true
      end
    end

    context "gibberish detection: low quality triggers escalation" do
      it "escalates when response is empty" do
        allow(mock_ollama).to receive(:generate).and_return({
                                                              content: "",
                                                              tool_calls: [],
                                                              model: "homunculus-workhorse",
                                                              usage: { prompt_tokens: 100, completion_tokens: 1,
                                                                       total_tokens: 101 },
                                                              finish_reason: :stop,
                                                              cost_usd: 0.0,
                                                              metadata: {}
                                                            })
        stub_anthropic_generate

        response = router.generate(messages: messages)

        expect(response.cloud?).to be true
        expect(response.escalated?).to be true
        expect(response.escalated_from).to eq(:workhorse)
      end

      it "escalates when response is highly repetitive" do
        repetitive = (["the same word"] * 50).join(" ")
        allow(mock_ollama).to receive(:generate).and_return({
                                                              content: repetitive,
                                                              tool_calls: [],
                                                              model: "homunculus-workhorse",
                                                              usage: { prompt_tokens: 100, completion_tokens: 200,
                                                                       total_tokens: 300 },
                                                              finish_reason: :stop,
                                                              cost_usd: 0.0,
                                                              metadata: {}
                                                            })
        stub_anthropic_generate

        response = router.generate(messages: messages)

        expect(response.cloud?).to be true
        expect(response.escalated?).to be true
      end
    end

    context "tool use responses" do
      it "handles tool calls without escalation" do
        tool_calls = [{ id: "uuid-1", name: "echo", arguments: { text: "hi" } }]
        allow(mock_ollama).to receive(:generate).and_return({
                                                              content: nil,
                                                              tool_calls: tool_calls,
                                                              model: "homunculus-workhorse",
                                                              usage: { prompt_tokens: 100, completion_tokens: 20,
                                                                       total_tokens: 120 },
                                                              finish_reason: :tool_use,
                                                              cost_usd: 0.0,
                                                              metadata: {}
                                                            })

        response = router.generate(messages: messages)

        expect(response.tool_use?).to be true
        expect(response.tool_calls.size).to eq(1)
        expect(response.tool_calls.first[:name]).to eq("echo")
        expect(response.finish_reason).to eq(:tool_use)
        # Tool use with nil content should not trigger gibberish detection
        expect(response.local?).to be true
      end
    end

    context "streaming mode" do
      it "yields chunks via stream" do
        allow(mock_ollama).to receive(:generate_stream).and_return({
                                                                     content: "streamed content",
                                                                     tool_calls: [],
                                                                     model: "homunculus-workhorse",
                                                                     usage: { prompt_tokens: 100, completion_tokens: 50,
                                                                              total_tokens: 150 },
                                                                     finish_reason: :stop,
                                                                     cost_usd: 0.0,
                                                                     metadata: {}
                                                                   })

        chunks = []
        response = router.generate(messages: messages, stream: true) { |chunk| chunks << chunk }

        expect(response).to be_a(Homunculus::Agent::Models::Response)
        expect(response.content).to eq("streamed content")
      end
    end

    context "usage tracking" do
      it "records the response via tracker" do
        stub_ollama_generate

        expect(tracker).to receive(:record).with(an_instance_of(Homunculus::Agent::Models::Response))

        router.generate(messages: messages)
      end
    end

    context "context_window passthrough" do
      it "passes context_window from tier config to provider generate" do
        workhorse_config = models_config.dig("tiers", "workhorse")
        expected_context_window = workhorse_config["context_window"]

        allow(mock_ollama).to receive(:generate).with(
          hash_including(context_window: expected_context_window)
        ).and_return({
                       content: "Response with context.",
                       tool_calls: [],
                       model: "homunculus-workhorse",
                       usage: { prompt_tokens: 100, completion_tokens: 50, total_tokens: 150 },
                       finish_reason: :stop,
                       cost_usd: 0.0,
                       metadata: {}
                     })

        response = router.generate(messages: messages)
        expect(response.content).to eq("Response with context.")
      end
    end

    context "unknown tier" do
      it "raises ConfigError for unknown tier" do
        expect do
          router.generate(messages: messages, tier: :nonexistent)
        end.to raise_error(Homunculus::Agent::Models::ConfigError, /Unknown tier: nonexistent/)
      end
    end

    context "cloud escalation tier selection" do
      it "escalates whisper to cloud_fast" do
        allow(mock_ollama).to receive(:generate)
          .and_raise(Homunculus::Agent::Models::ProviderError, "timeout")
        stub_anthropic_generate

        response = router.generate(messages: messages, skill_name: "home_monitor")

        expect(response.escalated_from).to eq(:whisper)
      end

      it "escalates coder to cloud_standard" do
        allow(mock_ollama).to receive(:generate)
          .and_raise(Homunculus::Agent::Models::ProviderError, "timeout")

        allow(mock_anthropic).to receive(:generate).and_return({
                                                                 content: "Cloud code response",
                                                                 tool_calls: [],
                                                                 model: "claude-sonnet-4-5-20250929",
                                                                 usage: { prompt_tokens: 200, completion_tokens: 100,
                                                                          total_tokens: 300 },
                                                                 finish_reason: :stop,
                                                                 cost_usd: 0.005,
                                                                 metadata: {}
                                                               })

        response = router.generate(messages: messages, skill_name: "code_review")

        expect(response.escalated_from).to eq(:coder)
        expect(response.tier).to eq(:cloud_standard)
      end
    end
  end
end
