# frozen_string_literal: true

module Homunculus
  module Familiars
    # Abstract base class for all Familiars notification channels.
    # Subclasses must implement #deliver and may override #healthy?.
    class Channel
      include SemanticLogger::Loggable

      # Returns the symbolic name of this channel (e.g. :ntfy, :log).
      # Derived from the class name by default — override for custom names.
      def name
        self.class.name.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').downcase.to_sym
      end

      # Whether this channel is active and should receive deliveries.
      # Subclasses may override to check config.
      def enabled?
        raise NotImplementedError, "#{self.class}#enabled? must be implemented"
      end

      # Whether the channel's backend is reachable and operational.
      # Returns true by default; override for network-backed channels.
      def healthy?
        true
      end

      # Deliver a notification to this channel.
      # Must be implemented by subclasses.
      #
      # @param title   [String] short notification title
      # @param message [String] full notification body
      # @param priority [:low, :normal, :high] urgency level
      # @return [:delivered, :failed]
      def deliver(title:, message:, priority: :normal)
        raise NotImplementedError, "#{self.class}#deliver must be implemented"
      end
    end
  end
end
