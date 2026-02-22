# frozen_string_literal: true

require "roda"
require "json"

module Homunculus
  module Gateway
    class Server < Roda
      include Utils::Logging

      plugin :json
      plugin :json_parser
      plugin :halt
      plugin :heartbeat, path: "/health"

      route do |r|
        r.on "api/v1" do
          r.post "chat" do
            payload = r.params
            message = payload["message"]

            r.halt(400, { error: "message is required" }) unless message

            logger.info("Received chat request", message_length: message.length)

            # Delegate to agent loop
            result = Homunculus::Agent::Loop.run(message:)

            { response: result }
          end

          r.get "status" do
            {
              status: "running",
              version: Homunculus::VERSION,
              uptime_seconds: (Time.now - SERVER_START_TIME).to_i
            }
          end
        end
      end

      SERVER_START_TIME = Time.now

      def self.start(config)
        gateway = config.gateway
        gateway.validate!

        logger = SemanticLogger["Homunculus::Gateway"]
        logger.info("Starting gateway", host: gateway.host, port: gateway.port)

        require "puma"
        require "puma/configuration"
        require "puma/launcher"

        puma_config = Puma::Configuration.new do |c|
          c.bind "tcp://#{gateway.host}:#{gateway.port}"
          c.threads 2, 4
          c.workers 0 # Single process for agent state
          c.environment "production"
          c.app Server.app
          c.quiet
        end

        launcher = Puma::Launcher.new(puma_config)
        launcher.run
      end
    end
  end
end
