# frozen_string_literal: true

module Homunculus
  module Tools
    class WorkspaceRead < Base
      tool_name "workspace_read"
      description "Reads the contents of a file from the workspace directory."
      trust_level :trusted

      parameter :path, type: :string, description: "Relative path within the workspace directory"

      MAX_FILE_SIZE = 100_000 # 100KB limit for reading

      def execute(arguments:, session:)
        path = arguments[:path]
        return Result.fail("Missing required parameter: path") unless path

        workspace = resolve_workspace(session)
        workspace_real = File.realpath(workspace)
        full_path = File.expand_path(path, workspace_real)

        # Security: ensure the resolved path is under workspace/
        unless full_path.start_with?("#{workspace_real}/") || full_path == workspace_real
          return Result.fail("Access denied: path must be within the workspace directory")
        end

        return Result.fail("File not found: #{path}") unless File.exist?(full_path)

        return Result.fail("Not a file: #{path} (use workspace_list for directories)") unless File.file?(full_path)

        content = File.read(full_path, encoding: "utf-8")
        if content.bytesize > MAX_FILE_SIZE
          content = content[0...MAX_FILE_SIZE]
          Result.ok("#{content}\n\n⚠️ File truncated at #{MAX_FILE_SIZE} bytes.",
                    truncated: true, original_size: File.size(full_path))
        else
          Result.ok(content, size: content.bytesize)
        end
      rescue Errno::EACCES
        Result.fail("Permission denied: #{path}")
      rescue StandardError => e
        Result.fail("Failed to read file: #{e.message}")
      end

      private

      def resolve_workspace(_session)
        # Default workspace path; can be overridden via session config
        "./workspace"
      end
    end
  end
end
