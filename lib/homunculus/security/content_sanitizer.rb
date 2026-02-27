# frozen_string_literal: true

module Homunculus
  module Security
    module ContentSanitizer
      MAX_CONTENT_SIZE = 50_000

      # XML tags used in Homunculus system prompts — must be stripped from untrusted content
      PROMPT_SECTION_TAGS = %w[
        soul operating_instructions user_context system
        memory_context available_tools agent_tools_config content_safety
      ].freeze

      PROMPT_SECTION_PATTERN = Regexp.new(
        PROMPT_SECTION_TAGS.map { |tag| "</?#{Regexp.escape(tag)}>" }.join("|"),
        Regexp::IGNORECASE
      )

      # Common prompt injection phrases
      INJECTION_PATTERNS = [
        /ignore\s+(all\s+)?previous\s+instructions/i,
        /ignore\s+(all\s+)?prior\s+instructions/i,
        /ignore\s+(all\s+)?above\s+instructions/i,
        /disregard\s+(all\s+)?previous\s+instructions/i,
        /you\s+are\s+now\s+a\b/i,
        /act\s+as\s+(if\s+you\s+are\s+)?a\b/i,
        /pretend\s+you\s+are\b/i,
        /your\s+new\s+(instructions|role|purpose)\b/i,
        /\[INST\]/i,
        /<<SYS>>/i,
        /<\|im_start\|>/i,
        /SYSTEM:\s*you\s+are/i,
        /ASSISTANT:\s*I\s+will/i,
        /###\s*(system|instruction|human|assistant)\s*:/i
      ].freeze

      BEGIN_MARKER = "[WEB_CONTENT_BEGIN -- untrusted external data]"
      END_MARKER = "[WEB_CONTENT_END]"

      module_function

      def sanitize(content, source: "unknown")
        text = content.to_s
        # Normalize binary strings (e.g. shell/Docker output) to valid UTF-8
        text = text.dup.force_encoding(Encoding::UTF_8).scrub if text.encoding == Encoding::BINARY

        # 1. Strip prompt section XML tags
        text = strip_prompt_tags(text)

        # 2. Detect and replace injection patterns
        text = filter_injections(text)

        # 3. Truncate to max size
        text = text[0...MAX_CONTENT_SIZE] if text.bytesize > MAX_CONTENT_SIZE

        # 4. Wrap in untrusted content delimiters
        "#{BEGIN_MARKER}\nSource: #{source}\n\n#{text}\n#{END_MARKER}"
      end

      def strip_prompt_tags(text)
        text.gsub(PROMPT_SECTION_PATTERN, "")
      end

      def filter_injections(text)
        text = text.dup.force_encoding(Encoding::UTF_8).scrub if text.encoding == Encoding::BINARY
        INJECTION_PATTERNS.each do |pattern|
          text = text.gsub(pattern) { |match| "[FILTERED: #{match.length} chars]" }
        end
        text
      end
    end
  end
end
