# frozen_string_literal: true

module Homunculus
  module Interfaces
    class Telegram
      # Extracted Familiars wiring for the Telegram interface.
      # Keeps the main Telegram class under the ClassLength limit.
      module FamiliarsIntegration
        # Register send_notification tool if Familiars is enabled.
        def register_familiars_tool(registry)
          registry.register(Tools::SendNotification.new(familiars_dispatcher: @familiars_dispatcher))
        end
      end
    end
  end
end
