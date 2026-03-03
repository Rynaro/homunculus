# frozen_string_literal: true

module Homunculus
  module SAG
    module SearchBackend
      class Base
        def search(query:, limit: 5)
          raise NotImplementedError, "#{self.class}#search must be implemented"
        end

        def available?
          raise NotImplementedError, "#{self.class}#available? must be implemented"
        end
      end
    end
  end
end
