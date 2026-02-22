# frozen_string_literal: true

module Homunculus
  module Tools
    class WorkspaceList < Base
      tool_name "workspace_list"
      description "Lists files and directories in the workspace directory."
      trust_level :trusted

      parameter :path, type: :string, description: "Relative path within workspace (defaults to root)",
                       required: false
      parameter :recursive, type: :boolean, description: "List files recursively (default: false)",
                            required: false

      MAX_ENTRIES = 200

      def execute(arguments:, session:)
        rel_path = arguments.fetch(:path, ".")
        recursive = arguments.fetch(:recursive, false)

        workspace = resolve_workspace(session)
        workspace_real = File.realpath(workspace)
        full_path = File.expand_path(rel_path, workspace_real)

        # Security: ensure path is under workspace/
        unless full_path.start_with?("#{workspace_real}/") || full_path == workspace_real
          return Result.fail("Access denied: path must be within the workspace directory")
        end

        return Result.fail("Path not found: #{rel_path}") unless File.exist?(full_path)

        return Result.fail("Not a directory: #{rel_path}") unless File.directory?(full_path)

        entries = list_entries(full_path, workspace_real, recursive)

        if entries.size > MAX_ENTRIES
          entries = entries.first(MAX_ENTRIES)
          Result.ok(format_entries(entries) + "\n\n⚠️ Listing truncated at #{MAX_ENTRIES} entries.",
                    count: entries.size, truncated: true)
        else
          Result.ok(format_entries(entries), count: entries.size)
        end
      rescue StandardError => e
        Result.fail("Failed to list directory: #{e.message}")
      end

      private

      def list_entries(dir_path, workspace_root, recursive)
        pattern = recursive ? File.join(dir_path, "**", "*") : File.join(dir_path, "*")
        Dir.glob(pattern).map do |entry|
          rel = entry.sub("#{workspace_root}/", "")
          type = File.directory?(entry) ? "directory" : "file"
          size = File.directory?(entry) ? nil : File.size(entry)
          { name: rel, type:, size: }
        end
      end

      def format_entries(entries)
        entries.map do |e|
          size_str = e[:size] ? " (#{format_size(e[:size])})" : ""
          type_indicator = e[:type] == "directory" ? "/" : ""
          "  #{e[:name]}#{type_indicator}#{size_str}"
        end.join("\n")
      end

      def format_size(bytes)
        if bytes < 1024
          "#{bytes} B"
        elsif bytes < 1024 * 1024
          "#{(bytes / 1024.0).round(1)} KB"
        else
          "#{(bytes / (1024.0 * 1024)).round(1)} MB"
        end
      end

      def resolve_workspace(_session)
        "./workspace"
      end
    end
  end
end
