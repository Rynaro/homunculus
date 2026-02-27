# frozen_string_literal: true

require "fileutils"

module Homunculus
  module Tools
    class WorkspaceDelete < Base
      tool_name "workspace_delete"
      description "Deletes a file or directory from the workspace. Directories require recursive: true to confirm intent."
      trust_level :mixed
      requires_confirmation true

      parameter :path, type: :string, description: "Relative path within the workspace directory"
      parameter :recursive, type: :boolean,
                            description: "Delete directories and their contents recursively (default: false)",
                            required: false

      def execute(arguments:, session:)
        path = arguments[:path]
        return Result.fail("Missing required parameter: path") unless path

        recursive = arguments.fetch(:recursive, false)

        workspace = resolve_workspace(session)
        workspace_real = File.realpath(workspace)
        full_path = File.expand_path(path, workspace_real)

        # Security: path must be strictly inside workspace, never the root itself
        unless full_path.start_with?("#{workspace_real}/")
          return Result.fail("Access denied: path must be within the workspace directory")
        end

        return Result.fail("File not found: #{path}") unless File.exist?(full_path)

        if File.directory?(full_path)
          return Result.fail("#{path} is a directory — pass recursive: true to delete it") unless recursive

          FileUtils.rm_rf(full_path)
          Result.ok("Deleted directory #{path}", path:, type: "directory", recursive: true)
        else
          File.delete(full_path)
          Result.ok("Deleted #{path}", path:, type: "file")
        end
      rescue Errno::EACCES
        Result.fail("Permission denied: #{path}")
      rescue StandardError => e
        Result.fail("Failed to delete: #{e.message}")
      end

      private

      def resolve_workspace(_session)
        "./workspace"
      end
    end
  end
end
