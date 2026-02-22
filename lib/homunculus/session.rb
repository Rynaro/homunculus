# frozen_string_literal: true

require "securerandom"

module Homunculus
  class Session
    attr_reader :id, :messages, :created_at, :total_input_tokens, :total_output_tokens, :turn_count
    attr_accessor :status, :pending_tool_call, :source, :forced_provider, :active_agent, :enabled_skills

    def initialize
      @id = SecureRandom.uuid
      @messages = []
      @created_at = Time.now
      @updated_at = Time.now
      @total_input_tokens = 0
      @total_output_tokens = 0
      @turn_count = 0
      @status = :active
      @pending_tool_call = nil
      @source = nil
      @forced_provider = nil
      @active_agent = :default
      @enabled_skills = Set.new
    end

    def add_message(role:, content:, tool_calls: nil)
      @messages << {
        role: role.to_sym,
        content:,
        tool_calls:,
        timestamp: Time.now
      }
      @updated_at = Time.now
      @turn_count += 1 if role.to_sym == :assistant
    end

    def add_tool_result(tool_call:, result:, trust_level: :trusted)
      content = result.to_s

      # Sanitize untrusted/mixed content before it enters the message history
      if %i[mixed untrusted].include?(trust_level) && result.success
        content = Security::ContentSanitizer.sanitize(content, source: tool_call.name)
      end

      @messages << {
        role: :tool,
        tool_call_id: tool_call.id,
        tool_name: tool_call.name,
        content:,
        success: result.success,
        timestamp: Time.now
      }
      @updated_at = Time.now
    end

    def track_usage(usage)
      return unless usage

      @total_input_tokens += usage.input_tokens || 0
      @total_output_tokens += usage.output_tokens || 0
    end

    # Returns messages formatted for API consumption (provider-agnostic)
    def messages_for_api
      @messages.map do |m|
        entry = { role: m[:role].to_s, content: m[:content] }
        entry[:tool_calls] = m[:tool_calls] if m[:tool_calls]
        entry[:tool_call_id] = m[:tool_call_id] if m[:tool_call_id]
        entry[:tool_name] = m[:tool_name] if m[:tool_name]
        entry.compact
      end
    end

    def active? = @status == :active
    def duration = Time.now - @created_at

    # Returns a Ractor-safe snapshot of the session context.
    # Only includes data needed for agent prompt building (not mutable state).
    def to_shareable
      recent_messages = @messages.last(10).map do |m|
        { role: m[:role].to_s, content: m[:content].to_s }
      end

      {
        id: @id,
        messages: recent_messages,
        summary: session_summary_text,
        turn_count: @turn_count,
        active_agent: @active_agent.to_s,
        enabled_skills: @enabled_skills.to_a.map(&:to_s)
      }
    end

    # Enable a skill by name.
    def enable_skill(name)
      @enabled_skills.add(name.to_s)
    end

    # Disable a skill by name.
    def disable_skill(name)
      @enabled_skills.delete(name.to_s)
    end

    # Check if a skill is enabled.
    def skill_enabled?(name)
      @enabled_skills.include?(name.to_s)
    end

    def summary
      {
        id: @id,
        status: @status,
        turn_count: @turn_count,
        total_input_tokens: @total_input_tokens,
        total_output_tokens: @total_output_tokens,
        duration_seconds: duration.round(1),
        message_count: @messages.size,
        active_agent: @active_agent,
        enabled_skills: @enabled_skills.to_a
      }
    end

    private

    # Brief text summary of the session for agent context.
    def session_summary_text
      return nil if @messages.empty?

      user_msgs = @messages.select { |m| m[:role] == :user }.last(3)
      return nil if user_msgs.empty?

      "Recent conversation topics: #{user_msgs.map { |m| m[:content].to_s[0...100] }.join("; ")}"
    end
  end
end
