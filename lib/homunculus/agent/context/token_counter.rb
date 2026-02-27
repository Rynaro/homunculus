# frozen_string_literal: true

module Homunculus
  module Agent
    module Context
      # Lightweight token estimator and text truncator — pure Ruby, no gem dependencies.
      #
      # estimate(text) — word-boundary heuristic:
      #   tokens ≈ words * 1.3 + punctuation_chars * 0.3
      #
      # truncate_to_tokens(text, max_tokens) — binary search over word boundaries to find
      # the largest prefix whose estimate fits within max_tokens.
      module TokenCounter
        module_function

        PUNCTUATION_PATTERN = /[.,!?;:'"()\[\]{}-]/

        # Returns 0 for nil or empty text.
        #
        # @param text [String, nil]
        # @return [Float]
        def estimate(text)
          return 0.0 if text.nil? || text.empty?

          words       = text.split.length
          punctuation = text.scan(PUNCTUATION_PATTERN).length

          (words * 1.3) + (punctuation * 0.3)
        end

        # Returns the full text when it already fits within max_tokens.
        # Otherwise binary-searches over word boundaries to find the largest
        # prefix whose estimate does not exceed max_tokens.
        #
        # Always truncates at a word boundary — never mid-word.
        #
        # @param text [String, nil]
        # @param max_tokens [Numeric]
        # @return [String]
        def truncate_to_tokens(text, max_tokens)
          return "" if text.nil? || text.empty?
          return text if estimate(text) <= max_tokens

          words = text.split
          lo    = 0
          hi    = words.length

          while lo < hi
            mid    = (lo + hi + 1) / 2
            prefix = words.first(mid).join(" ")

            if estimate(prefix) <= max_tokens
              lo = mid
            else
              hi = mid - 1
            end
          end

          words.first(lo).join(" ")
        end
      end
    end
  end
end
