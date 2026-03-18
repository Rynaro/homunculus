# frozen_string_literal: true

module Homunculus
  module Interfaces
    class TUI
      # Extracted model management commands: /models, /model <tier>, /routing on|off.
      module ModelManagementHelpers
        def show_models
          forced  = @session&.forced_tier&.to_s
          routing = @session&.routing_enabled ? "on" : "off"
          lines   = ["Available model tiers:", ""] + build_models_tier_lines(forced)
          lines << ""
          lines << "Routing: #{routing} | Override: #{forced || "none"}"
          lines << "Use /model <tier> to set override · /routing on|off to toggle"
          write_overlay(lines)
        end

        def handle_model_command(input)
          parts = input.to_s.strip.split(/\s+/, 2)
          tier_name = parts[1]&.strip
          return show_model if tier_name.nil? || tier_name.empty?

          valid_tiers = @models_toml_data ? (@models_toml_data["tiers"] || {}).keys : []
          if valid_tiers.any? && !valid_tiers.include?(tier_name)
            write_overlay(["Unknown tier: #{tier_name}", "", "Valid tiers: #{valid_tiers.join(", ")}"])
            return
          end

          @session.forced_tier  = tier_name.to_sym
          @session.forced_model = tier_name
          @session.first_message_sent = false
          note = if @session.routing_enabled
                   " (takes effect on next message; routing is on)"
                 else
                   " (routing is off — used for all messages)"
                 end
          write_overlay(["Model override set: #{tier_name}#{note}"])
        end

        def handle_routing_command(input)
          arg = input.to_s.strip.split(/\s+/, 2)[1]&.strip&.downcase
          lines = routing_command_lines(arg)
          write_overlay(lines)
        end

        private

        def build_models_tier_lines(forced)
          tiers = @models_toml_data ? (@models_toml_data["tiers"] || {}) : {}
          if tiers.empty?
            mc = use_models_router? ? nil : resolve_model_config
            return ["  #{@provider_name} — #{mc ? (mc.default_model || mc.model) : "router"}"]
          end
          tiers.flat_map do |name, cfg|
            cfg = {} unless cfg.is_a?(Hash)
            active_marker = forced == name ? " [active override]" : ""
            row = ["  /model #{name}#{active_marker} — #{cfg["model"] || "unknown"}"]
            row << "    #{cfg["description"]}" unless (cfg["description"] || "").empty?
            row
          end
        end

        def routing_command_lines(arg)
          case arg
          when "on"
            @session.routing_enabled = true
            ["Routing ON — the router will select the best model automatically."]
          when "off"
            @session.routing_enabled = false
            tier_info = @session.forced_tier ? "using tier: #{@session.forced_tier}" : "set a tier with /model <tier>"
            ["Routing OFF — #{tier_info}. All messages will use the forced tier."]
          when nil, ""
            state = @session&.routing_enabled ? "on" : "off"
            tier  = @session&.forced_tier || "none"
            ["Routing: #{state} | Forced tier: #{tier}", "", "Use /routing on or /routing off to toggle."]
          else
            ["Usage: /routing on | /routing off"]
          end
        end

        def write_overlay(lines)
          @messages_mutex.synchronize { @overlay_content = lines }
          refresh_all
        end
      end
    end
  end
end
