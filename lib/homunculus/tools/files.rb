# frozen_string_literal: true

require "pathname"

module Homunculus
  module Tools
    # Shared concern for workspace path validation.
    # Include in any tool that needs to resolve and validate paths
    # against the agent workspace boundary.
    #
    # The including class must implement #workspace_path returning
    # the absolute workspace directory path.
    module PathValidation
      # Resolves a relative path within the workspace and validates it
      # does not escape the workspace boundary.
      #
      # @param path [String] relative or absolute path to validate
      # @param workspace [String] workspace root directory
      # @return [Pathname] resolved absolute path
      # @raise [SecurityError] if path escapes workspace
      def validate_path!(path, workspace:)
        workspace_resolved = Pathname.new(workspace).expand_path.realpath
        resolved = Pathname.new(path).expand_path(workspace_resolved)

        # Resolve symlinks if the path exists (prevents symlink escape)
        resolved = resolved.realpath if resolved.exist?

        unless resolved.to_s.start_with?("#{workspace_resolved}/") || resolved == workspace_resolved
          raise SecurityError, "Path #{path} escapes workspace boundary"
        end

        resolved
      end

      # Validates that a path component does not contain null bytes
      # or other dangerous characters.
      #
      # @param path [String] path to sanitize
      # @return [String] sanitized path
      # @raise [SecurityError] if path contains dangerous characters
      def sanitize_path!(path)
        raise SecurityError, "Path is empty" if path.nil? || path.to_s.strip.empty?
        raise SecurityError, "Path contains null bytes" if path.include?("\0")

        path
      end
    end
  end
end
