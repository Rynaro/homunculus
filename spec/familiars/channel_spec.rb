# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/homunculus/familiars/channel"

RSpec.describe Homunculus::Familiars::Channel do
  # Concrete subclass for testing
  let(:concrete_channel_class) do
    Class.new(described_class) do
      def name = :test_channel
      def enabled? = true
    end
  end

  let(:channel) { concrete_channel_class.new }

  describe "#deliver" do
    it "raises NotImplementedError when not implemented" do
      expect { channel.deliver(title: "Test", message: "Hello") }
        .to raise_error(NotImplementedError, /deliver must be implemented/)
    end
  end

  describe "#healthy?" do
    it "returns true by default" do
      expect(channel.healthy?).to be true
    end
  end

  describe "#enabled?" do
    it "returns true for our concrete subclass" do
      expect(channel.enabled?).to be true
    end
  end

  describe "#name" do
    it "returns the channel name" do
      expect(channel.name).to eq(:test_channel)
    end
  end

  describe "subclass with no enabled? implementation" do
    let(:bare_class) { Class.new(described_class) }
    let(:bare_channel) { bare_class.new }

    it "raises NotImplementedError for enabled?" do
      expect { bare_channel.enabled? }.to raise_error(NotImplementedError, /enabled\? must be implemented/)
    end
  end
end
