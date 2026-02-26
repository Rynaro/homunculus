# frozen_string_literal: true

module Homunculus
  module Security
    module ThreatPatterns
      Pattern = Data.define(:id, :regex, :severity, :description, :category)

      SEVERITY_ORDER = { info: 0, warn: 1, block: 2 }.freeze

      PATTERNS = [
        # Exfiltration patterns
        Pattern.new(
          id: :ext_url,
          regex: %r{https?://\S+}i,
          severity: :warn,
          description: "External URL reference",
          category: :exfiltration
        ),
        Pattern.new(
          id: :ext_webhook,
          regex: /(?:webhook|callback|ngrok|requestbin)/i,
          severity: :block,
          description: "Webhook or callback exfiltration endpoint",
          category: :exfiltration
        ),
        Pattern.new(
          id: :ext_base64,
          regex: /base64\s*(?:encode|encoding)/i,
          severity: :warn,
          description: "Base64 encode instruction",
          category: :exfiltration
        ),
        Pattern.new(
          id: :ext_env,
          regex: /ENV\[|process\.env/i,
          severity: :block,
          description: "Environment variable access attempt",
          category: :exfiltration
        ),

        # Shell patterns
        Pattern.new(
          id: :shell_curl,
          regex: /\b(?:curl|wget|nc)\b/i,
          severity: :warn,
          description: "Network fetch command (curl/wget/nc)",
          category: :shell
        ),
        Pattern.new(
          id: :shell_reverse,
          regex: %r{bash\s+-i|/dev/tcp|mkfifo}i,
          severity: :block,
          description: "Reverse shell pattern",
          category: :shell
        ),

        # Injection patterns
        Pattern.new(
          id: :inj_ignore,
          regex: /(?:ignore|disregard)\s+(?:all\s+)?(?:previous|prior|above)\s+instructions/i,
          severity: :block,
          description: "Ignore/disregard instructions injection",
          category: :injection
        ),
        Pattern.new(
          id: :inj_role,
          regex: /you\s+are\s+now\b|act\s+as\s+(?:if\s+you\s+are\s+)?a\b|pretend\s+you\s+are\b/i,
          severity: :block,
          description: "Role override injection",
          category: :injection
        ),
        Pattern.new(
          id: :inj_xml,
          regex: %r{</?(?:system|soul|operating_instructions)>}i,
          severity: :block,
          description: "System XML tag injection",
          category: :injection
        ),
        Pattern.new(
          id: :inj_chatml,
          regex: /<\|im_start\|>|\[INST\]|<<SYS>>/i,
          severity: :block,
          description: "ChatML format marker injection",
          category: :injection
        ),

        # Filesystem patterns
        Pattern.new(
          id: :fs_sensitive,
          regex: %r{/etc/passwd|\.ssh/|\.env\b|credentials\.json|\.key\b}i,
          severity: :block,
          description: "Sensitive filesystem path reference",
          category: :filesystem
        ),
        Pattern.new(
          id: :fs_audit,
          regex: /audit\.jsonl.*(?:write|delete|truncate|\brm\b|>>?)|(?:write|delete|truncate|\brm\b|>>?).*audit\.jsonl/i,
          severity: :block,
          description: "Audit log tampering attempt",
          category: :filesystem
        )
      ].freeze

      module_function

      # Scans text line-by-line against all threat patterns.
      # Returns an array of finding hashes, each containing:
      #   :pattern     — the matching Pattern instance
      #   :line_number — 1-based line number of the match
      #   :match_text  — the matched string fragment
      def scan(text)
        findings = []
        text.to_s.each_line.with_index(1) do |line, line_number|
          PATTERNS.each do |pattern|
            next unless (match = line.match(pattern.regex))

            findings << { pattern: pattern, line_number: line_number, match_text: match[0] }
          end
        end
        findings
      end

      # Returns the highest severity found across all findings.
      # Severity order: :block > :warn > :info
      # Returns :info when findings is empty.
      def max_severity(findings)
        return :info if findings.empty?

        findings
          .map { |f| f[:pattern].severity }
          .max_by { |s| SEVERITY_ORDER.fetch(s, 0) }
      end
    end
  end
end
