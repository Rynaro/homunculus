# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Memory::Embedder do
  describe ".cosine_similarity" do
    it "returns 1.0 for identical vectors" do
      v = [1.0, 2.0, 3.0]
      expect(described_class.cosine_similarity(v, v)).to be_within(0.001).of(1.0)
    end

    it "returns 0.0 for orthogonal vectors" do
      a = [1.0, 0.0]
      b = [0.0, 1.0]
      expect(described_class.cosine_similarity(a, b)).to be_within(0.001).of(0.0)
    end

    it "returns -1.0 for opposite vectors" do
      a = [1.0, 0.0]
      b = [-1.0, 0.0]
      expect(described_class.cosine_similarity(a, b)).to be_within(0.001).of(-1.0)
    end

    it "returns 0.0 for nil inputs" do
      expect(described_class.cosine_similarity(nil, [1.0])).to eq(0.0)
      expect(described_class.cosine_similarity([1.0], nil)).to eq(0.0)
    end

    it "returns 0.0 for empty vectors" do
      expect(described_class.cosine_similarity([], [])).to eq(0.0)
    end

    it "returns 0.0 for mismatched lengths" do
      expect(described_class.cosine_similarity([1.0], [1.0, 2.0])).to eq(0.0)
    end

    it "returns 0.0 for zero vectors" do
      expect(described_class.cosine_similarity([0.0, 0.0], [1.0, 2.0])).to eq(0.0)
    end

    it "computes correct similarity for known vectors" do
      a = [1.0, 2.0, 3.0]
      b = [4.0, 5.0, 6.0]
      # dot = 4+10+18 = 32
      # |a| = sqrt(14), |b| = sqrt(77)
      expected = 32.0 / (Math.sqrt(14) * Math.sqrt(77))
      expect(described_class.cosine_similarity(a, b)).to be_within(0.001).of(expected)
    end
  end

  describe ".pack_embedding / .unpack_embedding" do
    it "roundtrips an embedding vector" do
      original = [0.1, 0.2, 0.3, -0.5, 1.0]
      packed = described_class.pack_embedding(original)
      unpacked = described_class.unpack_embedding(packed)

      expect(unpacked.length).to eq(original.length)
      original.zip(unpacked).each do |orig, unp|
        expect(unp).to be_within(0.0001).of(orig)
      end
    end

    it "returns nil for nil blob" do
      expect(described_class.unpack_embedding(nil)).to be_nil
    end

    it "produces binary blob output" do
      packed = described_class.pack_embedding([1.0, 2.0])
      expect(packed).to be_a(String)
      expect(packed.encoding).to eq(Encoding::ASCII_8BIT)
    end
  end

  describe "#available?" do
    it "returns false when Ollama is not reachable" do
      embedder = described_class.new(base_url: "http://127.0.0.1:99999")
      expect(embedder.available?).to be false
    end
  end

  describe "#embed" do
    it "returns nil when Ollama is not reachable" do
      embedder = described_class.new(base_url: "http://127.0.0.1:99999")
      expect(embedder.embed("test text")).to be_nil
    end
  end
end
