# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/homunculus/familiars/channel"
require_relative "../../lib/homunculus/familiars/registry"
require_relative "../../lib/homunculus/familiars/dispatcher"

RSpec.describe Homunculus::Familiars::Dispatcher do
  subject(:dispatcher) { described_class.new(registry:) }

  let(:registry) { Homunculus::Familiars::Registry.new }

  def make_channel(name, enabled: true, deliver_result: :delivered)
    ch = instance_double(Homunculus::Familiars::Channel)
    allow(ch).to receive(:is_a?).with(Homunculus::Familiars::Channel).and_return(true)
    allow(ch).to receive_messages(name: name.to_sym, enabled?: enabled, healthy?: true, deliver: deliver_result)
    ch
  end

  describe "#notify" do
    it "returns a hash with per-channel results" do
      log_ch = make_channel(:log)
      registry.register(log_ch)

      results = dispatcher.notify(title: "Test", message: "Hello", priority: :normal)

      expect(results).to eq(log: :delivered)
    end

    it "delivers to all enabled channels" do
      ch1 = make_channel(:log)
      ch2 = make_channel(:ntfy)
      registry.register(ch1)
      registry.register(ch2)

      results = dispatcher.notify(title: "Test", message: "Hello")

      expect(results).to eq(log: :delivered, ntfy: :delivered)
      expect(ch1).to have_received(:deliver).with(title: "Test", message: "Hello", priority: :normal)
      expect(ch2).to have_received(:deliver).with(title: "Test", message: "Hello", priority: :normal)
    end

    it "skips disabled channels" do
      enabled  = make_channel(:log, enabled: true)
      disabled = make_channel(:ntfy, enabled: false)
      registry.register(enabled)
      registry.register(disabled)

      results = dispatcher.notify(title: "Test", message: "Hello")

      expect(results.keys).to contain_exactly(:log)
      expect(disabled).not_to have_received(:deliver)
    end

    context "when one channel raises an error" do
      it "still delivers to other channels and marks the failed channel as :failed" do
        good_ch = make_channel(:log)
        bad_ch  = make_channel(:ntfy)
        allow(bad_ch).to receive(:deliver).and_raise(RuntimeError, "Network error")

        registry.register(good_ch)
        registry.register(bad_ch)

        results = dispatcher.notify(title: "Test", message: "Hello")

        expect(results[:log]).to eq(:delivered)
        expect(results[:ntfy]).to eq(:failed)
        expect(good_ch).to have_received(:deliver)
      end
    end

    it "passes the priority to each channel" do
      ch = make_channel(:log)
      registry.register(ch)

      dispatcher.notify(title: "Alert", message: "Urgent!", priority: :high)

      expect(ch).to have_received(:deliver).with(title: "Alert", message: "Urgent!", priority: :high)
    end
  end

  describe "#status" do
    it "returns health and delivery stats for all registered channels" do
      ch = make_channel(:log, enabled: true)
      registry.register(ch)

      status = dispatcher.status

      expect(status[:log]).to include(
        enabled: true,
        healthy: true,
        deliveries: 0,
        failures: 0
      )
    end

    it "increments delivery count on successful delivery" do
      ch = make_channel(:log)
      registry.register(ch)

      dispatcher.notify(title: "T", message: "M")
      dispatcher.notify(title: "T", message: "M")

      expect(dispatcher.status[:log][:deliveries]).to eq(2)
      expect(dispatcher.status[:log][:failures]).to eq(0)
    end

    it "increments failure count on channel error" do
      ch = make_channel(:ntfy)
      allow(ch).to receive(:deliver).and_raise("boom")
      registry.register(ch)

      dispatcher.notify(title: "T", message: "M")

      expect(dispatcher.status[:ntfy][:failures]).to eq(1)
    end

    it "includes disabled channels in status" do
      ch = make_channel(:ntfy, enabled: false)
      registry.register(ch)

      status = dispatcher.status

      expect(status[:ntfy][:enabled]).to be false
    end
  end
end
