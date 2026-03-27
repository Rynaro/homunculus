# frozen_string_literal: true

require "httpx"
require "json"

module Homunculus
  module Familiars
    module Channels
      # ntfy HTTP push notification channel.
      # Sends notifications via HTTP POST to a self-hosted ntfy server.
      #
      # Priority mapping:
      #   :low    → ntfy priority 2 (low)
      #   :normal → ntfy priority 3 (default)
      #   :high   → ntfy priority 5 (urgent)
      class Ntfy < Channel
        NTFY_PRIORITY_MAP = {
          low: 2,
          normal: 3,
          high: 5
        }.freeze

        HEALTH_CACHE_TTL = 60 # seconds

        def initialize(config:)
          @config = config
          @last_health_check_at = nil
          @last_health_result   = nil
          @health_mutex = Mutex.new
        end

        def name
          :ntfy
        end

        def enabled?
          @config.enabled && !@config.url.to_s.strip.empty?
        end

        # Lightweight HEAD health check to the ntfy base URL, cached for 60s.
        def healthy?
          @health_mutex.synchronize do
            return @last_health_result if @last_health_check_at &&
                                          (Time.now - @last_health_check_at) < HEALTH_CACHE_TTL

            @last_health_result   = check_health
            @last_health_check_at = Time.now
            @last_health_result
          end
        end

        # POST a notification to ntfy.
        # Returns :delivered on HTTP 2xx, :failed otherwise.
        def deliver(title:, message:, priority: :normal)
          priority_val = NTFY_PRIORITY_MAP.fetch(priority.to_sym, NTFY_PRIORITY_MAP[:normal])
          topic_url = "#{@config.url.chomp("/")}/#{@config.topic}"

          payload = {
            topic: @config.topic,
            title: title.to_s,
            message: message.to_s,
            priority: priority_val
          }

          response = http_client.post(
            topic_url,
            json: payload,
            headers: build_headers
          )

          if response.status >= 200 && response.status < 300
            logger.debug("ntfy notification delivered", title:, priority:, status: response.status)
            :delivered
          else
            logger.warn("ntfy delivery failed", title:, status: response.status, body: response.body.to_s.slice(0, 200))
            :failed
          end
        rescue StandardError => e
          logger.error("ntfy channel error", title:, error: e.message)
          :failed
        end

        private

        def check_health
          response = http_client.get(@config.url)
          response.respond_to?(:status) && response.status < 500
        rescue StandardError => e
          logger.debug("ntfy health check failed", error: e.message)
          false
        end

        def build_headers
          headers = { "Content-Type" => "application/json" }
          token = @config.publish_token.to_s.strip
          headers["Authorization"] = "Bearer #{token}" unless token.empty?
          headers
        end

        def http_client
          HTTPX.with(timeout: { operation_timeout: 5 })
        end
      end
    end
  end
end
