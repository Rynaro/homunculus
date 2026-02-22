# frozen_string_literal: true

require "yaml"

module Homunculus
  module Skills
    # Immutable skill definition, loaded from workspace/skills/<name>/SKILL.md.
    # Parsed from YAML frontmatter + Markdown body.
    Skill = Data.define(:name, :description, :tools_required, :model_preference,
                        :auto_activate, :triggers, :body, :path) do
      def to_s
        "Skill(#{name})"
      end

      # Parse a SKILL.md file into a Skill object.
      # Format: YAML frontmatter (between ---) followed by Markdown body.
      def self.parse(file_path)
        content = File.read(file_path, encoding: "utf-8")

        raise ArgumentError, "SKILL.md must start with YAML frontmatter: #{file_path}" unless content.start_with?("---")

        # Split frontmatter from body
        parts = content.split(/^---\s*$/, 3)
        # parts[0] is empty (before first ---), parts[1] is YAML, parts[2] is body
        raise ArgumentError, "Invalid SKILL.md format: #{file_path}" if parts.length < 3

        frontmatter = YAML.safe_load(parts[1], permitted_classes: [Symbol])
        body = parts[2].strip

        new(
          name: frontmatter.fetch("name"),
          description: frontmatter.fetch("description", ""),
          tools_required: Array(frontmatter.fetch("tools_required", [])).map(&:to_s),
          model_preference: frontmatter.fetch("model_preference", "auto").to_sym,
          auto_activate: frontmatter.fetch("auto_activate", false),
          triggers: Array(frontmatter.fetch("triggers", [])).map(&:to_s),
          body: body,
          path: file_path.to_s
        )
      end
    end
  end
end
