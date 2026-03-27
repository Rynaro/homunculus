# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/homunculus/familiars/channel"
require_relative "../../../lib/homunculus/familiars/channels/log"

RSpec.describe Homunculus::Familiars::Channels::Log do
  subject(:channel) { described_class.new }

  describe "#name" do
    it "returns :log" do
      expect(channel.name).to eq(:log)
    end
  end

  describe "#enabled?" do
    it "is always true" do
      expect(channel.enabled?).to be true
    end
  end

  describe "#healthy?" do
    it "is always true" do
      expect(channel.healthy?).to be true
    end
  end

  describe "#deliver" do
    it "returns :delivered" do
      result = channel.deliver(title: "Test", message: "Hello", priority: :normal)
      expect(result).to eq(:delivered)
    end

    it "accepts all valid priorities" do
      %i[low normal high].each do |priority|
        expect(channel.deliver(title: "T", message: "M", priority:)).to eq(:delivered)
      end
    end

    it "truncates long messages gracefully" do
      long_msg = "x" * 1000
      expect { channel.deliver(title: "T", message: long_msg) }.not_to raise_error
    end

    it "uses default priority :normal when not specified" do
      expect(channel.deliver(title: "T", message: "M")).to eq(:delivered)
    end
  end
end
