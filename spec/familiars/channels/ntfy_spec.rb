# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/homunculus/familiars/channel"
require_relative "../../../lib/homunculus/familiars/channels/ntfy"

RSpec.describe Homunculus::Familiars::Channels::Ntfy do
  subject(:channel) { described_class.new(config: ntfy_config) }

  let(:ntfy_config) do
    instance_double(
      Homunculus::FamiliarsNtfyConfig,
      enabled: true,
      url: "http://ntfy.example.com:80",
      topic: "homunculus",
      publish_token: "test-token-abc"
    )
  end

  describe "#name" do
    it "returns :ntfy" do
      expect(channel.name).to eq(:ntfy)
    end
  end

  describe "#enabled?" do
    it "returns true when config.enabled is true and url is present" do
      expect(channel.enabled?).to be true
    end

    it "returns false when config.enabled is false" do
      allow(ntfy_config).to receive(:enabled).and_return(false)
      expect(channel.enabled?).to be false
    end

    it "returns false when url is blank" do
      allow(ntfy_config).to receive(:url).and_return("")
      expect(channel.enabled?).to be false
    end
  end

  describe "#deliver" do
    let(:ntfy_url) { "http://ntfy.example.com:80/homunculus" }

    before do
      stub_request(:post, ntfy_url)
        .to_return(status: 200, body: '{"id":"abc"}', headers: { "Content-Type" => "application/json" })
    end

    it "sends HTTP POST with correct JSON payload" do
      channel.deliver(title: "Test", message: "Hello", priority: :normal)

      expect(WebMock).to have_requested(:post, ntfy_url).with(
        body: hash_including("topic" => "homunculus", "title" => "Test", "message" => "Hello", "priority" => 3)
      )
    end

    it "maps :low priority to ntfy priority 2" do
      channel.deliver(title: "T", message: "M", priority: :low)

      expect(WebMock).to have_requested(:post, ntfy_url).with(
        body: hash_including("priority" => 2)
      )
    end

    it "maps :normal priority to ntfy priority 3" do
      channel.deliver(title: "T", message: "M", priority: :normal)

      expect(WebMock).to have_requested(:post, ntfy_url).with(
        body: hash_including("priority" => 3)
      )
    end

    it "maps :high priority to ntfy priority 5" do
      channel.deliver(title: "T", message: "M", priority: :high)

      expect(WebMock).to have_requested(:post, ntfy_url).with(
        body: hash_including("priority" => 5)
      )
    end

    it "includes Authorization Bearer header when token is configured" do
      channel.deliver(title: "T", message: "M")

      expect(WebMock).to have_requested(:post, ntfy_url).with(
        headers: { "Authorization" => "Bearer test-token-abc" }
      )
    end

    it "omits Authorization header when token is blank" do
      allow(ntfy_config).to receive(:publish_token).and_return("")
      channel.deliver(title: "T", message: "M")

      expect(WebMock).to(have_requested(:post, ntfy_url).with do |req|
        !req.headers.key?("Authorization")
      end)
    end

    it "returns :delivered on HTTP 200" do
      result = channel.deliver(title: "T", message: "M")
      expect(result).to eq(:delivered)
    end

    it "returns :delivered on HTTP 201" do
      stub_request(:post, ntfy_url).to_return(status: 201, body: "{}")
      result = channel.deliver(title: "T", message: "M")
      expect(result).to eq(:delivered)
    end

    context "when ntfy returns an error status" do
      before do
        stub_request(:post, ntfy_url).to_return(status: 403, body: "Forbidden")
      end

      it "returns :failed without raising" do
        result = channel.deliver(title: "T", message: "M")
        expect(result).to eq(:failed)
      end
    end

    context "when ntfy is unreachable" do
      before do
        stub_request(:post, ntfy_url).to_raise(StandardError.new("connection refused"))
      end

      it "returns :failed without raising" do
        expect { channel.deliver(title: "T", message: "M") }.not_to raise_error
        result = channel.deliver(title: "T", message: "M")
        expect(result).to eq(:failed)
      end
    end
  end

  describe "#healthy?" do
    before do
      stub_request(:get, "http://ntfy.example.com:80")
        .to_return(status: 200, body: "ok")
    end

    it "returns true when ntfy responds with 2xx" do
      expect(channel.healthy?).to be true
    end

    it "caches the result for 60 seconds" do
      channel.healthy? # first call
      channel.healthy? # should use cache

      expect(WebMock).to have_requested(:get, "http://ntfy.example.com:80").once
    end

    context "when ntfy is unreachable" do
      before do
        stub_request(:get, "http://ntfy.example.com:80").to_raise(StandardError.new("timeout"))
      end

      it "returns false without raising" do
        # Reset health cache by creating a fresh channel
        fresh_channel = described_class.new(config: ntfy_config)
        expect(fresh_channel.healthy?).to be false
      end
    end

    context "when ntfy returns 5xx" do
      before do
        stub_request(:get, "http://ntfy.example.com:80").to_return(status: 503)
      end

      it "returns false" do
        fresh_channel = described_class.new(config: ntfy_config)
        expect(fresh_channel.healthy?).to be false
      end
    end
  end
end
