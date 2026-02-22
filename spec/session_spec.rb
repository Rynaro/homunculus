# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Session do
  subject(:session) { described_class.new }

  describe "#initialize" do
    it "generates a unique UUID" do
      session2 = described_class.new
      expect(session.id).not_to eq(session2.id)
      expect(session.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "starts with active status" do
      expect(session.status).to eq(:active)
    end

    it "starts with zero tokens" do
      expect(session.total_input_tokens).to eq(0)
      expect(session.total_output_tokens).to eq(0)
    end

    it "starts with zero turns" do
      expect(session.turn_count).to eq(0)
    end
  end

  describe "#add_message" do
    it "adds a message to the history" do
      session.add_message(role: :user, content: "Hello")

      expect(session.messages.size).to eq(1)
      expect(session.messages.first[:role]).to eq(:user)
      expect(session.messages.first[:content]).to eq("Hello")
    end

    it "increments turn count for assistant messages" do
      session.add_message(role: :user, content: "Hello")
      session.add_message(role: :assistant, content: "Hi there")

      expect(session.turn_count).to eq(1)
    end

    it "does not increment turn count for user messages" do
      session.add_message(role: :user, content: "Hello")
      session.add_message(role: :user, content: "Hello again")

      expect(session.turn_count).to eq(0)
    end

    it "supports tool_calls in messages" do
      tool_calls = [double(name: "echo", id: "123", arguments: { text: "hi" })]
      session.add_message(role: :assistant, content: nil, tool_calls:)

      expect(session.messages.last[:tool_calls]).to eq(tool_calls)
    end
  end

  describe "#add_tool_result" do
    it "adds a tool result message" do
      tool_call = Homunculus::Agent::ModelProvider::ToolCall.new(
        id: "tc-1", name: "echo", arguments: { text: "hello" }
      )
      result = Homunculus::Tools::Result.ok("hello")

      session.add_tool_result(tool_call:, result:)

      expect(session.messages.size).to eq(1)
      expect(session.messages.first[:role]).to eq(:tool)
      expect(session.messages.first[:tool_call_id]).to eq("tc-1")
      expect(session.messages.first[:content]).to eq("hello")
    end
  end

  describe "#track_usage" do
    it "accumulates token usage" do
      usage1 = Homunculus::Agent::ModelProvider::TokenUsage.new(input_tokens: 100, output_tokens: 50)
      usage2 = Homunculus::Agent::ModelProvider::TokenUsage.new(input_tokens: 200, output_tokens: 75)

      session.track_usage(usage1)
      session.track_usage(usage2)

      expect(session.total_input_tokens).to eq(300)
      expect(session.total_output_tokens).to eq(125)
    end

    it "handles nil usage gracefully" do
      expect { session.track_usage(nil) }.not_to raise_error
    end
  end

  describe "#messages_for_api" do
    it "returns messages in API format" do
      session.add_message(role: :user, content: "Hello")
      session.add_message(role: :assistant, content: "Hi")

      api_messages = session.messages_for_api

      expect(api_messages).to eq([
                                   { role: "user", content: "Hello" },
                                   { role: "assistant", content: "Hi" }
                                 ])
    end

    it "includes tool_call_id for tool results" do
      tool_call = Homunculus::Agent::ModelProvider::ToolCall.new(
        id: "tc-1", name: "echo", arguments: { text: "hi" }
      )
      session.add_tool_result(
        tool_call:,
        result: Homunculus::Tools::Result.ok("hi")
      )

      api_messages = session.messages_for_api
      expect(api_messages.first[:tool_call_id]).to eq("tc-1")
    end
  end

  describe "#summary" do
    it "returns a summary hash" do
      summary = session.summary

      expect(summary).to include(:id, :status, :turn_count, :total_input_tokens,
                                 :total_output_tokens, :duration_seconds, :message_count)
    end
  end
end
