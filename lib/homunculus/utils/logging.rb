# frozen_string_literal: true

require "semantic_logger"

module Homunculus
  module Utils
    module Logging
      def self.included(base)
        base.include(SemanticLogger::Loggable)
      end

      def self.setup(level: :info)
        SemanticLogger.default_level = level
        SemanticLogger.add_appender(io: $stderr, formatter: :json) if SemanticLogger.appenders.empty?
      end
    end
  end
end
