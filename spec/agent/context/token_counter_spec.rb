# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/homunculus/agent/context/token_counter"

RSpec.describe Homunculus::Agent::Context::TokenCounter do
  describe ".estimate" do
    it "returns 0 for nil text" do
      expect(described_class.estimate(nil)).to eq(0.0)
    end

    it "returns 0 for empty string" do
      expect(described_class.estimate("")).to eq(0.0)
    end

    it "returns a reasonable count for a known short phrase" do
      # "Hello world" — 2 words, 0 punctuation → 2 * 1.3 + 0 * 0.3 = 2.6
      result = described_class.estimate("Hello world")

      expect(result).to be_within(0.1).of(2.6)
    end

    it "counts punctuation contribution separately from words" do
      plain = "Hello world foo bar"
      punctuated = "Hello, world! foo? bar."

      # Same four words; punctuated version adds 4 * 0.3 = 1.2 extra
      expect(described_class.estimate(punctuated)).to be > described_class.estimate(plain)
    end

    it "applies the word * 1.3 + punctuation * 0.3 formula" do
      # 3 words, 2 punctuation chars → 3 * 1.3 + 2 * 0.3 = 3.9 + 0.6 = 4.5
      result = described_class.estimate("one, two! three")

      expect(result).to be_within(0.01).of(4.5)
    end
  end

  describe "encoding safety" do
    it "handles ASCII-8BIT encoded text in estimate without raising encoding errors" do
      binary = "Hello, world! foo? bar.".b

      expect { described_class.estimate(binary) }.not_to raise_error
      expect(described_class.estimate(binary)).to be > 0
    end

    it "handles ASCII-8BIT encoded text in truncate_to_tokens without raising encoding errors" do
      binary = ("word " * 50).strip.b

      expect { described_class.truncate_to_tokens(binary, 20) }.not_to raise_error
    end
  end

  describe ".truncate_to_tokens" do
    it "returns empty string for nil text" do
      expect(described_class.truncate_to_tokens(nil, 100)).to eq("")
    end

    it "returns empty string for empty text" do
      expect(described_class.truncate_to_tokens("", 100)).to eq("")
    end

    it "returns full text when estimate is within budget" do
      text = "Hello world"

      # estimate("Hello world") ≈ 2.6, well under 100
      expect(described_class.truncate_to_tokens(text, 100)).to eq(text)
    end

    it "truncates long text to approximately the right token count" do
      # Build a 200-word string whose estimate far exceeds a small budget
      long_text = (["word"] * 200).join(" ")
      result    = described_class.truncate_to_tokens(long_text, 20)

      expect(described_class.estimate(result)).to be <= 20
      # Should keep as many words as possible — not collapse to empty
      expect(result).not_to be_empty
    end

    it "truncates at word boundaries, never mid-word" do
      words     = %w[alpha beta gamma delta epsilon zeta eta theta]
      long_text = words.join(" ")
      result    = described_class.truncate_to_tokens(long_text, 5)

      # Every token in the result must be a complete word from the original list
      result.split.each do |token|
        expect(words).to include(token)
      end
    end

    it "returns no more than max_tokens worth of content" do
      long_text = ("The quick brown fox jumps over the lazy dog. " * 50).strip
      max       = 50
      result    = described_class.truncate_to_tokens(long_text, max)

      expect(described_class.estimate(result)).to be <= max
    end
  end
end
