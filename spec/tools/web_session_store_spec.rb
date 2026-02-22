# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Tools::WebSessionStore do
  subject(:store) { described_class.new(max_sessions: 3, ttl: 60) }

  describe "#get_or_create" do
    it "returns a cookie hash for a new session" do
      cookies = store.get_or_create("session-1")

      expect(cookies).to be_a(Hash)
      expect(cookies).to be_empty
    end

    it "returns the same cookies hash for the same session_id" do
      cookies1 = store.get_or_create("session-1")
      cookies2 = store.get_or_create("session-1")

      expect(cookies1).to equal(cookies2)
    end

    it "returns different cookies for different session_ids" do
      cookies1 = store.get_or_create("session-1")
      cookies2 = store.get_or_create("session-2")

      expect(cookies1).not_to equal(cookies2)
    end

    it "evicts oldest session when max is reached" do
      store.get_or_create("s1")
      store.get_or_create("s2")
      store.get_or_create("s3")

      # Adding a 4th should evict s1
      store.get_or_create("s4")

      expect(store.active_count).to eq(3)
    end

    it "evicts expired sessions" do
      store.get_or_create("old-session")

      # Simulate time passing beyond TTL
      allow(Time).to receive(:now).and_return(Time.now + 120)

      store.get_or_create("new-session")

      expect(store.active_count).to eq(1)
    end
  end

  describe "#destroy" do
    it "removes a specific session" do
      store.get_or_create("session-1")
      store.get_or_create("session-2")

      store.destroy("session-1")

      expect(store.active_count).to eq(1)
    end

    it "is safe to call with unknown session_id" do
      expect { store.destroy("nonexistent") }.not_to raise_error
    end
  end

  describe "#active_count" do
    it "returns 0 for empty store" do
      expect(store.active_count).to eq(0)
    end

    it "returns correct count" do
      store.get_or_create("s1")
      store.get_or_create("s2")

      expect(store.active_count).to eq(2)
    end
  end
end
