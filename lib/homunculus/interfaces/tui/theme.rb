# frozen_string_literal: true

module Homunculus
  module Interfaces
    class TUI
      # Warm color palette and decorative constants for the TUI.
      # Uses 256-color ANSI when available; falls back to 16-color for basic terminals.
      module Theme
        # 256-color palette (foreground: \e[38;5;Nm, background: \e[48;5;Nm)
        C256 = {
          user: "\e[38;5;75m",        # soft sky blue
          assistant: "\e[38;5;108m", # warm sage green
          info: "\e[38;5;183m",      # lavender mist
          error: "\e[38;5;174m",     # soft coral
          accent: "\e[38;5;214m",    # warm amber
          muted: "\e[38;5;245m",     # gentle gray
          warm_highlight: "\e[38;5;223m", # warm sand (e.g. inline code)
          local_tier: "\e[32m",      # green (16-color)
          cloud_tier: "\e[33m",      # yellow (16-color)
          escalated_tier: "\e[41m"   # bg red (16-color)
        }.freeze

        # 16-color fallback (same semantic keys)
        C16 = {
          user: "\e[36m",
          assistant: "\e[32m",
          info: "\e[2m",
          error: "\e[31m",
          accent: "\e[33m",
          muted: "\e[2m",
          warm_highlight: "\e[33m",
          local_tier: "\e[32m",
          cloud_tier: "\e[33m",
          escalated_tier: "\e[41m"
        }.freeze

        # Style modifiers (same in 16 and 256)
        RESET = "\e[0m"
        BOLD = "\e[1m"
        DIM = "\e[2m"
        ITALIC = "\e[3m"
        UNDERLINE = "\e[4m"
        REVERSE = "\e[7m"

        # Decorative characters
        SEPARATOR_CHAR = "─"
        HEADER_TOP_CHAR = "━"
        HEADER_BOTTOM_CHAR = "·"
        HEADER_TITLE_FLANK = "··"
        BULLET_CHAR = "•"
        PROMPT_CHAR = "›"
        TURN_SEPARATOR = "· · ·"
        STATUS_SEP = " · "
        ROLE_USER = "▸"
        ROLE_ASSISTANT = "◆"
        ROLE_INFO = "○"
        ROLE_ERROR = "✖"

        class << self
          def use_256_colors?
            term = ENV["TERM"].to_s
            colorterm = ENV["COLORTERM"].to_s
            term.include?("256") || term.include?("256color") || colorterm == "truecolor" || colorterm == "24bit"
          end

          def palette
            use_256_colors? ? C256 : C16
          end

          def paint(text, *styles)
            codes = styles.filter_map { |s| ansi_for(s) }.join
            "#{codes}#{text}#{RESET}"
          end

          def ansi_for(style)
            case style
            when :reset then RESET
            when :bold then BOLD
            when :dim then DIM
            when :italic then ITALIC
            when :underline then UNDERLINE
            when :reverse then REVERSE
            when :user, :user_label then palette[:user]
            when :assistant, :assistant_label then palette[:assistant]
            when :info, :info_label then palette[:info]
            when :error, :error_label then palette[:error]
            when :accent then palette[:accent]
            when :muted then palette[:muted]
            when :warm_highlight then palette[:warm_highlight]
            when :green, :local_tier then palette[:local_tier]
            when :yellow, :cloud_tier then palette[:cloud_tier]
            when :bg_red, :escalated_tier then palette[:escalated_tier]
            when :bright_blue then palette[:accent]
            when :cyan then palette[:user]
            when :white then RESET
            else nil
            end
          end

          def visible_len(str)
            str.to_s.gsub(/\e\[[0-9;]*[mGKHF]/, "").length
          end
        end

        # Instance methods for TUI when including Theme
        def paint(text, *styles)
          Theme.paint(text, *styles)
        end

        def visible_len(str)
          Theme.visible_len(str)
        end
      end
    end
  end
end
