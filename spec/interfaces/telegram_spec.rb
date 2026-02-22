# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Interfaces::Telegram do
  subject(:adapter) { described_class.new(config:) }

  let(:bot_token) { "test-bot-token-123" }
  let(:allowed_user_ids) { [111_222_333] }
  let(:telegram_raw) do
    {
      "enabled" => true,
      "bot_token" => bot_token,
      "allowed_user_ids" => allowed_user_ids,
      "session_timeout_minutes" => 30,
      "max_message_length" => 4096,
      "typing_indicator" => false
    }
  end

  let(:config) do
    raw = TomlRB.load_file("config/default.toml")
    raw["interfaces"] ||= {}
    raw["interfaces"]["telegram"] = telegram_raw
    Homunculus::Config.new(raw)
  end

  # Stub out heavy dependencies so we can unit-test the adapter logic
  # Telegram::Bot::Api uses method_missing for API methods, so we use a plain double
  let(:bot_api) { double("Telegram::Bot::Api") } # rubocop:disable RSpec/VerifiedDoubles
  let(:bot_client) { instance_double(Telegram::Bot::Client, api: bot_api) }

  before do
    allow(Telegram::Bot::Client).to receive(:new).and_return(bot_client)
    # Return in-memory SQLite databases instead of file-based ones.
    # This avoids filesystem hits while keeping both memory store and budget tracker functional.
    allow(Sequel).to receive(:sqlite) { Sequel.connect("sqlite:/") }
  end

  # ── Initialization ─────────────────────────────────────────────

  describe "#initialize" do
    it "creates a bot client with the configured token" do
      adapter
      expect(Telegram::Bot::Client).to have_received(:new).with(bot_token)
    end

    it "raises if bot token is missing" do
      telegram_raw["bot_token"] = nil
      expect { adapter }.to raise_error(ArgumentError, /bot token is required/)
    end

    it "sets up allowed users from config" do
      expect(adapter.send(:authorized?, 111_222_333)).to be true
      expect(adapter.send(:authorized?, 999_999_999)).to be false
    end
  end

  # ── Authorization ──────────────────────────────────────────────

  describe "#authorized?" do
    it "allows whitelisted user IDs" do
      expect(adapter.send(:authorized?, 111_222_333)).to be true
    end

    it "rejects non-whitelisted user IDs silently" do
      expect(adapter.send(:authorized?, 999_999_999)).to be false
    end

    it "rejects nil user IDs" do
      expect(adapter.send(:authorized?, nil)).to be false
    end

    context "with empty whitelist (dev mode)" do
      let(:allowed_user_ids) { [] }

      it "allows any user" do
        expect(adapter.send(:authorized?, 123)).to be true
        expect(adapter.send(:authorized?, 456)).to be true
      end
    end
  end

  # ── Session Management ─────────────────────────────────────────

  describe "session management" do
    it "creates a new session for a new chat_id" do
      entry = adapter.send(:session_entry_for, 42)
      expect(entry.session).to be_a(Homunculus::Session)
      expect(entry.session.forced_provider).to be_nil
    end

    it "reuses an existing session for the same chat_id" do
      entry1 = adapter.send(:session_entry_for, 42)
      entry2 = adapter.send(:session_entry_for, 42)
      expect(entry1.session.id).to eq(entry2.session.id)
    end

    it "creates separate sessions for different chat_ids" do
      entry1 = adapter.send(:session_entry_for, 42)
      entry2 = adapter.send(:session_entry_for, 99)
      expect(entry1.session.id).not_to eq(entry2.session.id)
    end

    context "session timeout" do
      it "expires sessions after the configured timeout" do
        entry = adapter.send(:session_entry_for, 42)
        original_id = entry.session.id

        # Simulate timeout by backdating last_activity
        entry.last_activity = Time.now - (31 * 60)

        new_entry = adapter.send(:session_entry_for, 42)
        expect(new_entry.session.id).not_to eq(original_id)
      end

      it "preserves sessions within the timeout window" do
        entry = adapter.send(:session_entry_for, 42)
        original_id = entry.session.id

        entry.last_activity = Time.now - (29 * 60)

        same_entry = adapter.send(:session_entry_for, 42)
        expect(same_entry.session.id).to eq(original_id)
      end
    end

    describe "#cleanup_expired_sessions!" do
      it "removes expired sessions" do
        adapter.send(:session_entry_for, 1)
        adapter.send(:session_entry_for, 2)
        adapter.send(:session_entry_for, 3)

        # Expire session 2
        sessions = adapter.instance_variable_get(:@sessions)
        sessions[2].last_activity = Time.now - (31 * 60)

        adapter.send(:cleanup_expired_sessions!)

        expect(sessions.keys).to contain_exactly(1, 3)
      end
    end
  end

  # ── Message Splitting ──────────────────────────────────────────

  describe "#split_message" do
    it "returns a single chunk for short messages" do
      chunks = adapter.send(:split_message, "Hello")
      expect(chunks).to eq(["Hello"])
    end

    it "splits at paragraph boundaries" do
      text = "#{"A" * 2000}\n\n#{"B" * 2000}\n\n#{"C" * 100}"
      chunks = adapter.send(:split_message, text)
      expect(chunks.length).to be >= 2
      chunks.each { |c| expect(c.length).to be <= 4096 }
    end

    it "falls back to newline boundaries" do
      text = "#{"A" * 2000}\n#{"B" * 2000}\n#{"C" * 100}"
      chunks = adapter.send(:split_message, text)
      expect(chunks.length).to be >= 2
      chunks.each { |c| expect(c.length).to be <= 4096 }
    end

    it "handles text without any natural boundaries" do
      text = "A" * 10_000
      chunks = adapter.send(:split_message, text)
      expect(chunks.length).to be >= 3
      chunks.each { |c| expect(c.length).to be <= 4096 }
      expect(chunks.join).to eq(text)
    end

    it "does not split messages exactly at the limit" do
      text = "A" * 4096
      chunks = adapter.send(:split_message, text)
      expect(chunks).to eq([text])
    end
  end

  # ── Confirmation Flow ──────────────────────────────────────────

  describe "confirmation flow" do
    let(:tool_call) do
      Homunculus::Agent::ModelProvider::ToolCall.new(
        id: "tc-1", name: "shell_exec", arguments: { command: "ls -la" }
      )
    end

    it "sends inline keyboard for pending confirmations" do
      entry = adapter.send(:session_entry_for, 42)
      session = entry.session
      session.pending_tool_call = tool_call

      result = Homunculus::Agent::AgentResult.pending_confirmation(tool_call, session:)

      allow(bot_api).to receive(:send_message)

      adapter.send(:display_result, 42, result)

      expect(bot_api).to have_received(:send_message).with(
        hash_including(
          chat_id: 42,
          reply_markup: an_instance_of(Telegram::Bot::Types::InlineKeyboardMarkup)
        )
      )
    end
  end

  # ── Model Routing ───────────────────────────────────────────────

  describe "model routing" do
    it "starts with auto routing (nil forced_provider)" do
      entry = adapter.send(:session_entry_for, 42)
      expect(entry.session.forced_provider).to be_nil
    end

    it "supports forcing provider via session" do
      entry = adapter.send(:session_entry_for, 42)
      entry.session.forced_provider = :anthropic
      expect(entry.session.forced_provider).to eq(:anthropic)
    end

    it "preserves forced_provider within the same session" do
      entry = adapter.send(:session_entry_for, 42)
      entry.session.forced_provider = :anthropic

      same_entry = adapter.send(:session_entry_for, 42)
      expect(same_entry.session.forced_provider).to eq(:anthropic)
    end

    it "resets forced_provider when session expires" do
      entry = adapter.send(:session_entry_for, 42)
      entry.session.forced_provider = :anthropic

      # Expire the session
      entry.last_activity = Time.now - (31 * 60)

      new_entry = adapter.send(:session_entry_for, 42)
      # New session starts fresh with auto routing
      expect(new_entry.session.forced_provider).to be_nil
    end
  end

  # ── Escalation Disabled (Local-Only Mode) ──────────────────

  describe "escalation disabled" do
    around do |example|
      original = ENV.fetch("ESCALATION_ENABLED", nil)
      ENV["ESCALATION_ENABLED"] = "false"
      example.run
    ensure
      if original
        ENV["ESCALATION_ENABLED"] = original
      else
        ENV.delete("ESCALATION_ENABLED")
      end
    end

    let(:config) do
      raw = TomlRB.load_file("config/default.toml")
      raw["interfaces"] ||= {}
      raw["interfaces"]["telegram"] = telegram_raw
      raw["models"]["escalation"]["enabled"] = false
      Homunculus::Config.new(raw)
    end

    it "does not register anthropic provider" do
      agent_loop = adapter.instance_variable_get(:@agent_loop)
      providers = agent_loop.instance_variable_get(:@providers)
      expect(providers).not_to have_key(:anthropic)
      expect(providers).to have_key(:ollama)
    end

    it "returns disabled message for cmd_escalate" do
      allow(bot_api).to receive(:send_message)

      adapter.send(:cmd_escalate, 42)

      expect(bot_api).to have_received(:send_message).with(
        hash_including(
          chat_id: 42,
          text: a_string_matching(/Remote escalation is disabled/)
        )
      )
    end

    it "returns disabled message for cmd_budget" do
      allow(bot_api).to receive(:send_message)

      adapter.send(:cmd_budget, 42)

      expect(bot_api).to have_received(:send_message).with(
        hash_including(
          chat_id: 42,
          text: a_string_matching(/disabled/)
        )
      )
    end

    it "returns local-only text for budget_status_text" do
      text = adapter.send(:budget_status_text)
      expect(text).to include("disabled")
      expect(text).to include("local-only")
    end
  end

  # ── Helper Methods ─────────────────────────────────────────────

  describe "#escape_markdown" do
    it "escapes special Markdown characters" do
      expect(adapter.send(:escape_markdown, "hello_world")).to eq('hello\_world')
      expect(adapter.send(:escape_markdown, "a*b*c")).to eq('a\*b\*c')
    end

    it "handles nil gracefully" do
      expect(adapter.send(:escape_markdown, nil)).to eq("")
    end
  end

  describe "#truncate" do
    it "truncates long text with ellipsis" do
      expect(adapter.send(:truncate, "A" * 300, 200)).to eq("#{"A" * 197}...")
    end

    it "returns short text unchanged" do
      expect(adapter.send(:truncate, "hello", 200)).to eq("hello")
    end
  end
end
