# frozen_string_literal: true

module Homunculus
  module Tools
    class WebSessionStore
      MAX_SESSIONS = 10
      SESSION_TTL = 3600 # 1 hour

      SessionEntry = Struct.new(:cookies, :created_at, keyword_init: true)

      def initialize(max_sessions: MAX_SESSIONS, ttl: SESSION_TTL)
        @sessions = {}
        @max_sessions = max_sessions
        @ttl = ttl
        @mutex = Mutex.new
      end

      # Returns the cookie hash for a session, creating one if needed.
      # Cookies are stored as { "name" => "value" } pairs.
      def get_or_create(session_id)
        @mutex.synchronize do
          evict_expired!

          if @sessions.key?(session_id)
            @sessions[session_id].cookies
          else
            evict_oldest! if @sessions.size >= @max_sessions
            cookies = {}
            @sessions[session_id] = SessionEntry.new(cookies:, created_at: Time.now)
            cookies
          end
        end
      end

      def destroy(session_id)
        @mutex.synchronize do
          @sessions.delete(session_id)
        end
      end

      def active_count
        @mutex.synchronize do
          evict_expired!
          @sessions.size
        end
      end

      private

      def evict_expired!
        cutoff = Time.now - @ttl
        @sessions.reject! { |_, s| s.created_at < cutoff }
      end

      def evict_oldest!
        oldest_key = @sessions.min_by { |_, s| s.created_at }&.first
        @sessions.delete(oldest_key) if oldest_key
      end
    end
  end
end
