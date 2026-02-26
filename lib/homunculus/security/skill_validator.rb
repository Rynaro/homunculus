# frozen_string_literal: true

module Homunculus
  module Security
    class SkillValidator
      include SemanticLogger::Loggable

      Finding = Data.define(:pattern_id, :severity, :description, :category, :line_number, :match_text)

      ELEVATED_TOOLS = %w[shell_exec file_write web_fetch mqtt_publish scheduler_manage].freeze
      MAX_ELEVATED_TOOLS = 2

      # @param block_threshold [Symbol] :block (default) or :warn (strict mode)
      def initialize(block_threshold: :block)
        @block_threshold = block_threshold
      end

      # Validate a skill against threat patterns.
      # @param skill [Homunculus::Skills::Skill]
      # @return [Array(Boolean, Array<Finding>)] [passed, findings]
      def validate(skill)
        findings = []

        # Scan skill body for threat patterns
        scan_body(skill.body, findings)

        # Check frontmatter for elevated tool overuse
        check_elevated_tools(skill.tools_required, findings)

        threshold_level = ThreatPatterns::SEVERITY_ORDER[@block_threshold] || 2
        max_finding_level = findings.map { |f| ThreatPatterns::SEVERITY_ORDER.fetch(f.severity, 0) }.max || 0

        passed = max_finding_level < threshold_level
        [passed, findings]
      end

      private

      def scan_body(body, findings)
        ThreatPatterns.scan(body).each do |hit|
          findings << Finding.new(
            pattern_id: hit[:pattern].id,
            severity: hit[:pattern].severity,
            description: hit[:pattern].description,
            category: hit[:pattern].category,
            line_number: hit[:line_number],
            match_text: hit[:match_text]
          )
        end
      end

      def check_elevated_tools(tools_required, findings)
        elevated_count = tools_required.count { |t| ELEVATED_TOOLS.include?(t) }
        return unless elevated_count > MAX_ELEVATED_TOOLS

        findings << Finding.new(
          pattern_id: :elevated_tools_excess,
          severity: :warn,
          description: "Skill requires #{elevated_count} elevated tools (max recommended: #{MAX_ELEVATED_TOOLS})",
          category: :privilege,
          line_number: 0,
          match_text: tools_required.select { |t| ELEVATED_TOOLS.include?(t) }.join(", ")
        )
      end
    end
  end
end
