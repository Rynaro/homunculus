# frozen_string_literal: true

module Homunculus
  module Interfaces
    class TUI
      # Registry of slash commands for the TUI. Used for matching, suggestions, and dispatch.
      class CommandRegistry
        COMMANDS = {
          "/help" => { description: "Show available commands", handler: :show_help },
          "/status" => { description: "Session and config details", handler: :show_status },
          "/clear" => { description: "Clear chat history", handler: :clear },
          "/confirm" => { description: "Approve pending tool call", handler: :confirm },
          "/deny" => { description: "Reject pending tool call", handler: :deny },
          "/models" => { description: "List available model tiers", handler: :show_models },
          "/model" => { description: "Set model tier override (/model <tier>)", handler: :set_model },
          "/routing" => { description: "Toggle routing (/routing on|off)", handler: :set_routing },
          "/quit" => { description: "Exit", handler: :quit },
          "/exit" => { description: "Exit (alias)", handler: :quit },
          "/q" => { description: "Exit (alias)", handler: :quit }
        }.freeze

        # Returns the command key if +input+ is exactly a command or command with trailing space; otherwise nil.
        # +input+ is assumed to be user input (may be stripped by caller).
        def match(input)
          return nil if input.nil? || !input.to_s.start_with?("/")

          key = input.to_s.strip.split(/\s/, 2).first
          COMMANDS.key?(key) ? key : nil
        end

        # Returns an array of command strings that start with +partial+ (e.g. "/he" => ["/help"]).
        def suggestions(partial)
          return [] if partial.nil? || !partial.to_s.start_with?("/")

          COMMANDS.keys.select { |cmd| cmd.start_with?(partial.to_s) }.sort
        end

        # Returns an array of { command:, description: } for suggestions that start with +partial+.
        def suggestions_with_descriptions(partial)
          return [] if partial.nil? || !partial.to_s.start_with?("/")

          COMMANDS.keys
                  .select { |cmd| cmd.start_with?(partial.to_s) }
                  .sort
                  .map { |cmd| { command: cmd, description: COMMANDS[cmd][:description] } }
        end
      end
    end
  end
end
