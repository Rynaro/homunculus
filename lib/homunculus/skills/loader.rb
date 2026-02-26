# frozen_string_literal: true

require "pathname"

module Homunculus
  module Skills
    # Loads skill definitions from workspace/skills/ and provides matching and injection.
    #
    # Security constraints:
    # - Skills are local files only (no remote registries)
    # - Skills cannot modify agent SOUL.md or other skills
    # - Skills cannot add new tools — they only reference existing registered tools
    # - Skills cannot override confirmation requirements
    # - All skill files are read-only to the agent
    class Loader
      include SemanticLogger::Loggable

      # @param skills_dir [String, Pathname] path to workspace/skills/
      # @param validator [Homunculus::Security::SkillValidator, nil] optional validator for threat scanning
      def initialize(skills_dir:, validator: nil)
        @skills_dir = Pathname.new(skills_dir)
        @validator = validator
        @skills = {}
        load_all if @skills_dir.exist?
      end

      # All loaded skills.
      def all
        @skills.values
      end

      # Look up a skill by name.
      def [](name)
        @skills[name.to_s]
      end

      # Names of all loaded skills.
      def skill_names
        @skills.keys
      end

      # Number of loaded skills.
      def size
        @skills.size
      end

      # Returns skills whose auto_activate flag is true.
      def auto_activated
        @skills.values.select(&:auto_activate)
      end

      # Match skills relevant to a message, sorted by relevance.
      # Only considers enabled skills (passed as a Set of names).
      def match_skills(message:, enabled_skills: nil)
        candidates = if enabled_skills
                       @skills.values.select { |s| enabled_skills.include?(s.name) }
                     else
                       @skills.values
                     end

        candidates.select do |skill|
          skill.triggers.any? { |t| message.downcase.include?(t.downcase) }
        end.sort_by { |s| -relevance_score(s, message) }
      end

      # Inject matched skill context into a system prompt as XML sections.
      def inject_skill_context(skills:, system_prompt:)
        return system_prompt if skills.nil? || skills.empty?

        skill_xml = skills.map do |s|
          "<skill name=\"#{s.name}\" description=\"#{s.description}\">\n#{s.body}\n</skill>"
        end.join("\n")

        "#{system_prompt}\n\n<active_skills>\n#{skill_xml}\n</active_skills>"
      end

      # Validate that a skill only references tools that exist in the registry.
      def validate_tools(skill, tool_registry)
        return [] unless skill.tools_required.any?

        available = tool_registry.tool_names.to_set
        skill.tools_required.reject { |t| available.include?(t) }
      end

      # Validate all skill files and return findings hash.
      # @return [Hash{String => Array<Finding>}] skill name => findings
      def validate_all
        results = {}
        return results unless @skills_dir.exist?

        @skills_dir.children.select(&:directory?).each do |dir|
          skill_file = dir / "SKILL.md"
          next unless skill_file.exist?

          skill = Skill.parse(skill_file)
          _passed, findings = @validator.validate(skill) if @validator
          results[skill.name] = findings || []
        rescue StandardError => e
          logger.warn("Failed to parse skill for validation", dir: dir.basename.to_s, error: e.message)
        end

        results
      end

      # Reload all skills from disk.
      def reload!
        @skills.clear
        load_all if @skills_dir.exist?
        logger.info("Skills reloaded", count: @skills.size)
      end

      private

      def load_all
        @skills_dir.children.select(&:directory?).each do |dir|
          skill_file = dir / "SKILL.md"
          next unless skill_file.exist?

          skill = Skill.parse(skill_file)

          if @validator
            passed, findings = @validator.validate(skill)
            unless passed
              logger.warn("Skill blocked by validation", name: skill.name,
                                                         findings: findings.map(&:description))
              next
            end

            if findings.any?
              logger.info("Skill loaded with warnings", name: skill.name,
                                                        warnings: findings.map(&:description))
            end
          end

          @skills[skill.name] = skill
          logger.debug("Skill loaded", name: skill.name, triggers: skill.triggers.size,
                                       auto_activate: skill.auto_activate)
        rescue StandardError => e
          logger.warn("Failed to load skill from #{dir.basename}", error: e.message)
        end

        logger.info("Skills loaded", count: @skills.size, auto_activated: auto_activated.size)
      end

      # Score relevance based on number of trigger matches and match position.
      def relevance_score(skill, message)
        lower_msg = message.downcase
        score = 0

        skill.triggers.each do |trigger|
          lower_trigger = trigger.downcase
          next unless lower_msg.include?(lower_trigger)

          # Base score for match
          score += 10

          # Bonus for longer trigger matches (more specific)
          score += lower_trigger.length

          # Bonus for match near the start of the message
          pos = lower_msg.index(lower_trigger)
          score += (100 - [pos, 100].min) / 10 if pos
        end

        score
      end
    end
  end
end
