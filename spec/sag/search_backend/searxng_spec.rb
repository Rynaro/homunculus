# frozen_string_literal: true

require "webmock/rspec"
require "oj"
require_relative "../../../lib/homunculus/sag/search_backend/searxng"

RSpec.describe Homunculus::SAG::SearchBackend::SearXNG do
  subject(:backend) { described_class.new(base_url: "http://localhost:8888") }

  let(:base_search_url) { "http://localhost:8888/search" }
  let(:healthz_url)     { "http://localhost:8888/healthz" }

  let(:search_results) do
    [
      { "url" => "https://example.com/ruby", "title" => "Ruby Lang", "content" => "Ruby is a language." },
      { "url" => "https://example.com/rails", "title" => "Rails", "content" => "Rails is a framework." },
      { "url" => "https://example.com/gems", "title" => "RubyGems", "content" => "Gems are packages." }
    ]
  end

  let(:response_body) { { "results" => search_results } }

  describe "#search" do
    context "successful search" do
      before do
        stub_request(:get, base_search_url)
          .with(query: hash_including(q: "ruby", format: "json"))
          .to_return(
            status: 200,
            body: Oj.dump(response_body),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns an array of Snippets" do
        results = backend.search(query: "ruby", limit: 5)

        expect(results).to be_an(Array)
        expect(results).to all(be_a(Homunculus::SAG::Snippet))
      end

      it "maps url correctly" do
        results = backend.search(query: "ruby", limit: 5)

        expect(results.first.url).to eq("https://example.com/ruby")
      end

      it "maps title correctly" do
        results = backend.search(query: "ruby", limit: 5)

        expect(results.first.title).to eq("Ruby Lang")
      end

      it "maps body from content field" do
        results = backend.search(query: "ruby", limit: 5)

        expect(results.first.body).to eq("Ruby is a language.")
      end

      it "assigns rank starting at 1" do
        results = backend.search(query: "ruby", limit: 5)

        expect(results.first.rank).to eq(1)
        expect(results[1].rank).to eq(2)
        expect(results[2].rank).to eq(3)
      end

      it "sets source to :search" do
        results = backend.search(query: "ruby", limit: 5)

        expect(results.first.source).to eq(:search)
      end

      it "sets score to 0.0" do
        results = backend.search(query: "ruby", limit: 5)

        expect(results.first.score).to eq(0.0)
      end
    end

    context "respects limit" do
      before do
        large_results = Array.new(10) do |i|
          { "url" => "https://example.com/#{i}", "title" => "Result #{i}", "content" => "Body #{i}" }
        end

        stub_request(:get, base_search_url)
          .with(query: hash_including(q: "ruby"))
          .to_return(
            status: 200,
            body: Oj.dump({ "results" => large_results }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns at most limit results" do
        results = backend.search(query: "ruby", limit: 3)

        expect(results.length).to eq(3)
      end

      it "returns all results when limit exceeds available" do
        results = backend.search(query: "ruby", limit: 20)

        expect(results.length).to eq(10)
      end
    end

    context "uses content field" do
      before do
        stub_request(:get, base_search_url)
          .with(query: hash_including(q: "content_test"))
          .to_return(
            status: 200,
            body: Oj.dump({
                            "results" => [
                              { "url" => "https://example.com", "title" => "Title",
                                "content" => "Content text", "description" => "Description text" }
                            ]
                          }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "prefers content over description" do
        results = backend.search(query: "content_test", limit: 1)

        expect(results.first.body).to eq("Content text")
      end
    end

    context "falls back to description field" do
      before do
        stub_request(:get, base_search_url)
          .with(query: hash_including(q: "desc_test"))
          .to_return(
            status: 200,
            body: Oj.dump({
                            "results" => [
                              { "url" => "https://example.com", "title" => "Title",
                                "content" => nil, "description" => "Description fallback" }
                            ]
                          }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "uses description when content is nil" do
        results = backend.search(query: "desc_test", limit: 1)

        expect(results.first.body).to eq("Description fallback")
      end
    end

    context "HTTP error (non-200 response)" do
      before do
        stub_request(:get, base_search_url)
          .with(query: hash_including(q: "error_test"))
          .to_return(status: 503, body: "Service Unavailable")
      end

      it "returns empty array" do
        results = backend.search(query: "error_test")

        expect(results).to eq([])
      end
    end

    context "connection error" do
      before do
        stub_request(:get, base_search_url)
          .with(query: hash_including(q: "timeout_test"))
          .to_timeout
      end

      it "returns empty array" do
        results = backend.search(query: "timeout_test")

        expect(results).to eq([])
      end
    end

    context "malformed JSON" do
      before do
        stub_request(:get, base_search_url)
          .with(query: hash_including(q: "json_test"))
          .to_return(
            status: 200,
            body: "{ invalid json {{{{",
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns empty array" do
        results = backend.search(query: "json_test")

        expect(results).to eq([])
      end
    end

    context "empty results array" do
      before do
        stub_request(:get, base_search_url)
          .with(query: hash_including(q: "empty_test"))
          .to_return(
            status: 200,
            body: Oj.dump({ "results" => [] }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns empty array" do
        results = backend.search(query: "empty_test")

        expect(results).to eq([])
      end
    end

    context "with custom categories" do
      subject(:backend) { described_class.new(base_url: "http://localhost:8888", categories: %w[news science]) }

      before do
        stub_request(:get, base_search_url)
          .with(query: hash_including(categories: "news,science"))
          .to_return(
            status: 200,
            body: Oj.dump({ "results" => [] }),
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "joins categories with comma" do
        backend.search(query: "test")

        expect(WebMock).to have_requested(:get, base_search_url)
          .with(query: hash_including(categories: "news,science"))
      end
    end
  end

  describe "#available?" do
    context "when healthz returns 200" do
      before do
        stub_request(:get, healthz_url).to_return(status: 200, body: "OK")
      end

      it "returns true" do
        expect(backend.available?).to be true
      end
    end

    context "when healthz returns non-200" do
      before do
        stub_request(:get, healthz_url).to_return(status: 503, body: "Down")
      end

      it "returns false" do
        expect(backend.available?).to be false
      end
    end

    context "on connection error" do
      before do
        stub_request(:get, healthz_url).to_timeout
      end

      it "returns false" do
        expect(backend.available?).to be false
      end
    end
  end
end
