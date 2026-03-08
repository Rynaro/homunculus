# frozen_string_literal: true

require_relative "../../../lib/homunculus/sag/search_backend/base"

RSpec.describe Homunculus::SAG::SearchBackend::Base do
  subject(:backend) { described_class.new }

  describe "#search" do
    it "raises NotImplementedError" do
      expect { backend.search(query: "test") }.to raise_error(NotImplementedError)
    end

    it "includes the class name in the error message" do
      expect { backend.search(query: "test") }
        .to raise_error(NotImplementedError, /Homunculus::SAG::SearchBackend::Base#search/)
    end
  end

  describe "#available?" do
    it "raises NotImplementedError" do
      expect { backend.available? }.to raise_error(NotImplementedError)
    end

    it "includes the class name in the error message" do
      expect { backend.available? }
        .to raise_error(NotImplementedError, /Homunculus::SAG::SearchBackend::Base#available\?/)
    end
  end
end
