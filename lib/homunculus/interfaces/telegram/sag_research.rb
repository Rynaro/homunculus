# frozen_string_literal: true

require_relative "../concerns/sag_research"

module Homunculus
  module Interfaces
    class Telegram
      # Delegates to the shared Concerns::SAGResearch module.
      # Telegram uses @providers (Hash of ModelProvider instances),
      # which the shared module handles via build_sag_llm_via_providers.
      module SAGResearch
        include Concerns::SAGResearch
      end
    end
  end
end
