# frozen_string_literal: true

require_relative "../familiars/channel"
require_relative "../familiars/registry"
require_relative "../familiars/dispatcher"
require_relative "../familiars/channels/log"
require_relative "../familiars/channels/ntfy"

module Homunculus
  module Interfaces
    # Shared module for initializing the Familiars dispatcher in all interfaces.
    # Include this module and call build_familiars_dispatcher to get a configured
    # Dispatcher (or nil when Familiars is disabled).
    module FamiliarsSetup
      # Build and return a Familiars::Dispatcher from the current config.
      # Returns nil when familiars is disabled in config.
      def build_familiars_dispatcher
        return nil unless @config.familiars.enabled

        registry = Familiars::Registry.new

        # Log channel is always registered when Familiars is enabled
        registry.register(Familiars::Channels::Log.new)

        # ntfy channel is registered when explicitly enabled and URL is present
        if @config.familiars.ntfy.enabled && !@config.familiars.ntfy.url.to_s.strip.empty?
          registry.register(Familiars::Channels::Ntfy.new(config: @config.familiars.ntfy))
        end

        Familiars::Dispatcher.new(registry:)
      end

      # Wrap an existing deliver_fn so that Familiars also receives the notification.
      # The existing in-interface delivery is unchanged; Familiars is additive.
      #
      # @param original_fn [Proc, nil] existing deliver_fn ->(text, priority) { }
      # @param dispatcher  [Familiars::Dispatcher, nil]
      # @param title       [String] default title prefix for Familiars notifications
      # @return [Proc]
      def wrap_deliver_fn_with_familiars(original_fn:, dispatcher:, title: "Homunculus")
        lambda do |text, priority|
          # Existing delivery — always runs regardless of Familiars state
          original_fn&.call(text, priority)

          # Familiars delivery — additive, never blocks
          dispatcher&.notify(title:, message: text.to_s, priority: priority || :normal)
        rescue StandardError => e
          logger.error("Familiars deliver_fn wrapper error", error: e.message)
        end
      end
    end
  end
end
