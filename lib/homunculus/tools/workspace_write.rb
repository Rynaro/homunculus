# frozen_string_literal: true

require "fileutils"

module Homunculus
  module Tools
    class WorkspaceWrite < Base
      tool_name "workspace_write"
      description "Writes content to a file in the workspace directory. Creates parent directories if needed."
      trust_level :mixed
      requires_confirmation true

      parameter :path, type: :string, description: "Relative path within the workspace directory"
      parameter :content, type: :string, description: "Content to write to the file"
      parameter :mode, type: :string, description: "Write mode: 'overwrite' (default) or 'append'",
                       required: false, enum: %w[overwrite append]

      MAX_WRITE_SIZE = 1_000_000 # 1MB limit

      def execute(arguments:, session:)
        path = arguments[:path]
        content = arguments[:content]
        mode = arguments.fetch(:mode, "overwrite")

        return Result.fail("Missing required parameter: path") unless path
        return Result.fail("Missing required parameter: content") unless content

        return Result.fail("Content exceeds maximum write size of #{MAX_WRITE_SIZE} bytes") if content.bytesize > MAX_WRITE_SIZE

        workspace = resolve_workspace(session)
        workspace_real = File.realpath(workspace)
        full_path = File.expand_path(path, workspace_real)

        # Security: ensure the resolved path is under workspace/
        unless full_path.start_with?("#{workspace_real}/") || full_path == workspace_real
          return Result.fail("Access denied: path must be within the workspace directory")
        end

        # Create parent directories
        FileUtils.mkdir_p(File.dirname(full_path))

        # Write the file
        file_mode = mode == "append" ? "a" : "w"
        File.write(full_path, content, mode: file_mode, encoding: "utf-8")

        Result.ok("Written to #{path} (#{content.bytesize} bytes, #{mode})",
                  path:, size: content.bytesize, mode:)
      rescue Errno::EACCES
        Result.fail("Permission denied: #{path}")
      rescue StandardError => e
        Result.fail("Failed to write file: #{e.message}")
      end

      private

      def resolve_workspace(_session)
        "./workspace"
      end
    end
  end
end
