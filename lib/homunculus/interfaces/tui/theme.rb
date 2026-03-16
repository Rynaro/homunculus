# frozen_string_literal: true

module Homunculus
  module Interfaces
    class TUI
      # Warm color palette and decorative constants for the TUI.
      # Uses 256-color ANSI when available; falls back to 16-color for basic terminals.
      module Theme
        # 256-color palette (foreground: \e[38;5;Nm, background: \e[48;5;Nm)
        C256 = {
          user: "\e[38;5;75m",            # soft sky blue
          assistant: "\e[38;5;108m",      # warm sage green
          info: "\e[38;5;183m",           # lavender mist
          error: "\e[38;5;174m",          # soft coral
          accent: "\e[38;5;214m",         # warm amber
          muted: "\e[38;5;245m",          # gentle gray
          warm_highlight: "\e[38;5;223m", # warm sand (e.g. inline code)
          local_tier: "\e[38;5;71m",      # muted green
          cloud_tier: "\e[38;5;179m",     # muted gold
          escalated_tier: "\e[38;5;167m", # soft red fg (not bg)
          # background tints for chrome areas
          bg_header: "\e[48;5;235m",      # near-black warm tint
          bg_status: "\e[48;5;234m",      # darker than header
          bg_input: "\e[48;5;236m",       # slightly lighter warm tint
          bg_code: "\e[48;5;233m",        # deepest — code block bg
          # tier dot colors (used as foreground)
          dot_local: "\e[38;5;71m",       # green dot
          dot_cloud: "\e[38;5;179m",      # gold dot
          dot_escalated: "\e[38;5;167m"   # red dot
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
          escalated_tier: "\e[31m",
          bg_header: "\e[0m",
          bg_status: "\e[0m",
          bg_input: "\e[0m",
          bg_code: "\e[0m",
          dot_local: "\e[32m",
          dot_cloud: "\e[33m",
          dot_escalated: "\e[31m"
        }.freeze

        # Style modifiers (same in 16 and 256)
        RESET = "\e[0m"
        BOLD = "\e[1m"
        DIM = "\e[2m"
        ITALIC = "\e[3m"
        UNDERLINE = "\e[4m"
        REVERSE = "\e[7m"

        # Decorative characters — UTF-8 preferred; ASCII fallback detected at runtime.
        # These constants hold the preferred UTF-8 glyphs.  At runtime, always call the
        # class-method accessors (e.g. Theme.separator_char) which return the ASCII
        # variant when the terminal cannot handle UTF-8.
        SEPARATOR_CHAR_UTF8     = "─"
        SEPARATOR_CHAR_ASCII    = "-"
        HEADER_TOP_CHAR_UTF8    = "━"
        HEADER_TOP_CHAR_ASCII   = "="
        HEADER_BOTTOM_CHAR_UTF8 = "·"
        HEADER_BOTTOM_CHAR_ASCII = "."
        HEADER_TITLE_FLANK_UTF8 = "··"
        HEADER_TITLE_FLANK_ASCII = ".."
        BULLET_CHAR_UTF8        = "•"
        BULLET_CHAR_ASCII       = "*"
        PROMPT_CHAR_UTF8        = "›"
        PROMPT_CHAR_ASCII       = ">"
        TURN_SEPARATOR_UTF8     = "· · ·"
        TURN_SEPARATOR_ASCII    = "- - -"
        STATUS_SEP_UTF8         = " · "
        STATUS_SEP_ASCII        = " | "
        ROLE_USER_UTF8          = "▸"
        ROLE_USER_ASCII         = ">"
        ROLE_ASSISTANT_UTF8     = "◆"
        ROLE_ASSISTANT_ASCII    = "*"
        ROLE_INFO_UTF8          = "○"
        ROLE_INFO_ASCII         = "i"
        ROLE_ERROR_UTF8         = "✖"
        ROLE_ERROR_ASCII        = "!"

        # Legacy constant aliases — kept for compatibility; resolve at load time.
        # If the runtime process cannot determine UTF-8 support at constant-definition
        # time, they will be set to the UTF-8 variant and the accessor methods are
        # the canonical way to obtain the correct glyph at render time.
        SEPARATOR_CHAR     = SEPARATOR_CHAR_UTF8
        HEADER_TOP_CHAR    = HEADER_TOP_CHAR_UTF8
        HEADER_BOTTOM_CHAR = HEADER_BOTTOM_CHAR_UTF8
        HEADER_TITLE_FLANK = HEADER_TITLE_FLANK_UTF8
        BULLET_CHAR        = BULLET_CHAR_UTF8
        PROMPT_CHAR        = PROMPT_CHAR_UTF8
        TURN_SEPARATOR     = TURN_SEPARATOR_UTF8
        STATUS_SEP         = STATUS_SEP_UTF8
        ROLE_USER          = ROLE_USER_UTF8
        ROLE_ASSISTANT     = ROLE_ASSISTANT_UTF8
        ROLE_INFO          = ROLE_INFO_UTF8
        ROLE_ERROR         = ROLE_ERROR_UTF8

        class << self
          # Returns true when the environment signals UTF-8 support.
          # Checks LANG, LC_ALL, LC_CTYPE, and TERM in order of precedence.
          def utf8_capable?
            [ENV.fetch("LC_ALL", nil), ENV.fetch("LC_CTYPE", nil), ENV.fetch("LANG", nil)].each do |val|
              return val.to_s.upcase.include?("UTF-8") || val.to_s.upcase.include?("UTF8") if val && !val.empty?
            end
            # VTE / modern terminals always support UTF-8 regardless of LANG.
            term = ENV["TERM"].to_s
            term.include?("xterm") || term.include?("vte") || term.include?("kitty") || term.include?("alacritty")
          end

          # Accessor methods — return the appropriate glyph for the terminal.
          def separator_char     = utf8_capable? ? SEPARATOR_CHAR_UTF8     : SEPARATOR_CHAR_ASCII
          def header_top_char    = utf8_capable? ? HEADER_TOP_CHAR_UTF8    : HEADER_TOP_CHAR_ASCII
          def header_bottom_char = utf8_capable? ? HEADER_BOTTOM_CHAR_UTF8 : HEADER_BOTTOM_CHAR_ASCII
          def header_title_flank = utf8_capable? ? HEADER_TITLE_FLANK_UTF8 : HEADER_TITLE_FLANK_ASCII
          def bullet_char        = utf8_capable? ? BULLET_CHAR_UTF8        : BULLET_CHAR_ASCII
          def prompt_char        = utf8_capable? ? PROMPT_CHAR_UTF8        : PROMPT_CHAR_ASCII
          def turn_separator     = utf8_capable? ? TURN_SEPARATOR_UTF8     : TURN_SEPARATOR_ASCII
          def status_sep         = utf8_capable? ? STATUS_SEP_UTF8         : STATUS_SEP_ASCII
          def role_user          = utf8_capable? ? ROLE_USER_UTF8          : ROLE_USER_ASCII
          def role_assistant     = utf8_capable? ? ROLE_ASSISTANT_UTF8     : ROLE_ASSISTANT_ASCII
          def role_info          = utf8_capable? ? ROLE_INFO_UTF8          : ROLE_INFO_ASCII
          def role_error         = utf8_capable? ? ROLE_ERROR_UTF8         : ROLE_ERROR_ASCII

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

          # rubocop:disable Metrics/CyclomaticComplexity
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
            when :bg_header then palette[:bg_header]
            when :bg_status then palette[:bg_status]
            when :bg_input then palette[:bg_input]
            when :bg_code then palette[:bg_code]
            end
          end
          # rubocop:enable Metrics/CyclomaticComplexity

          # Returns a colored tier indicator dot string for the given tier symbol.
          # Tier is one of: :local, :cloud, :escalated. Falls back to a neutral dot.
          def model_dot(tier)
            dot = utf8_capable? ? "●" : "o"
            color = case tier&.to_sym
                    when :local     then palette[:dot_local]
                    when :cloud     then palette[:dot_cloud]
                    when :escalated then palette[:dot_escalated]
                    else palette[:muted]
                    end
            "#{color}#{dot}#{RESET}"
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
