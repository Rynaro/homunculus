# frozen_string_literal: true

module Homunculus
  module Familiars
    # Holds the set of registered notification channels.
    # Channels are identified by their symbolic name.
    class Registry
      def initialize
        @channels = {}
      end

      # Register a channel instance.
      # Raises ArgumentError if the object is not a Channel subclass.
      def register(channel)
        raise ArgumentError, "Must be a Familiars::Channel instance" unless channel.is_a?(Channel)

        @channels[channel.name] = channel
      end

      # Iterate over all channels that are currently enabled.
      def each_enabled(&)
        @channels.values.select(&:enabled?).each(&)
      end

      # Look up a channel by name.
      # @param name [Symbol, String]
      # @return [Channel, nil]
      def get(name)
        @channels[name.to_sym]
      end

      # All registered channel names.
      def channel_names
        @channels.keys
      end

      # Number of registered channels.
      def size
        @channels.size
      end
    end
  end
end
