# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/homunculus/familiars/channel"
require_relative "../../lib/homunculus/familiars/registry"

RSpec.describe Homunculus::Familiars::Registry do
  subject(:registry) { described_class.new }

  def make_channel(name, enabled: true)
    ch = instance_double(Homunculus::Familiars::Channel)
    allow(ch).to receive(:is_a?).with(Homunculus::Familiars::Channel).and_return(true)
    allow(ch).to receive_messages(name: name.to_sym, enabled?: enabled)
    ch
  end

  describe "#register" do
    it "registers a channel by name" do
      ch = make_channel(:ntfy)
      registry.register(ch)
      expect(registry.get(:ntfy)).to eq(ch)
    end

    it "raises ArgumentError for non-Channel objects" do
      expect { registry.register("not a channel") }
        .to raise_error(ArgumentError, /Familiars::Channel instance/)
    end

    it "overwrites an existing channel with the same name" do
      ch1 = make_channel(:log)
      ch2 = make_channel(:log)
      registry.register(ch1)
      registry.register(ch2)
      expect(registry.get(:log)).to eq(ch2)
    end
  end

  describe "#each_enabled" do
    it "yields only enabled channels" do
      enabled_ch = make_channel(:log, enabled: true)
      disabled_ch = make_channel(:ntfy, enabled: false)
      registry.register(enabled_ch)
      registry.register(disabled_ch)

      yielded = []
      registry.each_enabled { |ch| yielded << ch }

      expect(yielded).to contain_exactly(enabled_ch)
    end

    it "yields all channels when all are enabled" do
      ch1 = make_channel(:log, enabled: true)
      ch2 = make_channel(:ntfy, enabled: true)
      registry.register(ch1)
      registry.register(ch2)

      yielded = []
      registry.each_enabled { |ch| yielded << ch }

      expect(yielded).to contain_exactly(ch1, ch2)
    end

    it "yields nothing when all channels are disabled" do
      ch = make_channel(:ntfy, enabled: false)
      registry.register(ch)

      yielded = []
      registry.each_enabled { |ch| yielded << ch }

      expect(yielded).to be_empty
    end
  end

  describe "#get" do
    it "returns nil for unknown channel" do
      expect(registry.get(:unknown)).to be_nil
    end

    it "accepts string keys" do
      ch = make_channel(:log)
      registry.register(ch)
      expect(registry.get("log")).to eq(ch)
    end
  end

  describe "#channel_names" do
    it "returns all registered channel names" do
      registry.register(make_channel(:log))
      registry.register(make_channel(:ntfy))
      expect(registry.channel_names).to contain_exactly(:log, :ntfy)
    end

    it "returns empty array for empty registry" do
      expect(registry.channel_names).to be_empty
    end
  end

  describe "#size" do
    it "returns the count of registered channels" do
      expect(registry.size).to eq(0)
      registry.register(make_channel(:log))
      expect(registry.size).to eq(1)
      registry.register(make_channel(:ntfy))
      expect(registry.size).to eq(2)
    end
  end
end
