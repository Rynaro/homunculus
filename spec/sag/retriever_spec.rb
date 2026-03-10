# frozen_string_literal: true

require "webmock/rspec"
require_relative "../../lib/homunculus/sag/search_backend/base"
require_relative "../../lib/homunculus/sag/retriever"

RSpec.describe Homunculus::SAG::Retriever do
  let(:backend) { instance_double(Homunculus::SAG::SearchBackend::Base) }
  let(:search_snippets) do
    [
      Homunculus::SAG::Snippet.from_search(url: "https://example.com/1", title: "First", body: "Short body", rank: 1),
      Homunculus::SAG::Snippet.from_search(url: "https://example.com/2", title: "Second", body: "Another body", rank: 2),
      Homunculus::SAG::Snippet.from_search(url: "https://example.com/3", title: "Third", body: "Third body", rank: 3),
      Homunculus::SAG::Snippet.from_search(url: "https://example.com/4", title: "Fourth", body: "Fourth body", rank: 4)
    ]
  end

  before do
    allow(backend).to receive(:search).and_return(search_snippets)
  end

  describe "#retrieve without deep_fetch" do
    subject(:retriever) { described_class.new(backend: backend, deep_fetch: false, top_n: 5) }

    it "delegates to backend search" do
      retriever.retrieve(query: "test")

      expect(backend).to have_received(:search).with(query: "test", limit: 5)
    end

    it "returns snippets from backend" do
      result = retriever.retrieve(query: "test")

      expect(result.size).to eq(4)
      expect(result.first.url).to eq("https://example.com/1")
    end

    it "passes top_n as limit" do
      custom = described_class.new(backend: backend, deep_fetch: false, top_n: 3)
      custom.retrieve(query: "test")

      expect(backend).to have_received(:search).with(query: "test", limit: 3)
    end
  end

  describe "#retrieve with deep_fetch" do
    subject(:retriever) { described_class.new(backend: backend, deep_fetch: true, top_n: 5) }

    before do
      stub_request(:get, "https://example.com/1")
        .to_return(status: 200, body: "<html><body><p>Full content page one</p></body></html>")
      stub_request(:get, "https://example.com/2")
        .to_return(status: 200, body: "<html><body><p>Full content page two</p></body></html>")
      stub_request(:get, "https://example.com/3")
        .to_return(status: 200, body: "<html><body><p>Full content page three</p></body></html>")
      stub_request(:get, "https://example.com/4")
        .to_return(status: 200, body: "<html><body><p>Page four</p></body></html>")
    end

    it "replaces shallow snippets with deep-fetched content" do
      result = retriever.retrieve(query: "test")

      expect(result.first.body).to include("Full content page one")
      expect(result.first.source).to eq(:deep_fetch)
    end

    it "only deep-fetches top MAX_DEEP_FETCH_COUNT results" do
      result = retriever.retrieve(query: "test")

      deep_fetched = result.select { |s| s.source == :deep_fetch }
      expect(deep_fetched.size).to eq(described_class::MAX_DEEP_FETCH_COUNT)
      expect(result[3].source).to eq(:search)
    end

    it "preserves original snippet on HTTP failure" do
      stub_request(:get, "https://example.com/1").to_return(status: 500)

      result = retriever.retrieve(query: "test")

      expect(result.first.source).to eq(:search)
      expect(result.first.body).to eq("Short body")
    end

    it "preserves original snippet on connection timeout" do
      stub_request(:get, "https://example.com/1").to_timeout

      result = retriever.retrieve(query: "test")

      expect(result.first.source).to eq(:search)
    end

    it "truncates body at MAX_DEEP_FETCH_CHARS" do
      long_content = "x" * 5000
      stub_request(:get, "https://example.com/1")
        .to_return(status: 200, body: "<html><body>#{long_content}</body></html>")

      result = retriever.retrieve(query: "test")

      expect(result.first.body.length).to be <= described_class::MAX_DEEP_FETCH_CHARS
    end

    it "removes script and style tags" do
      html = <<~HTML
        <html><body>
          <script>alert('xss')</script>
          <style>.hidden{display:none}</style>
          <p>Actual content</p>
        </body></html>
      HTML
      stub_request(:get, "https://example.com/1").to_return(status: 200, body: html)

      result = retriever.retrieve(query: "test")

      expect(result.first.body).to include("Actual content")
      expect(result.first.body).not_to include("alert")
      expect(result.first.body).not_to include("display:none")
    end

    it "preserves rank from original snippet" do
      result = retriever.retrieve(query: "test")

      expect(result.first.rank).to eq(1)
      expect(result[1].rank).to eq(2)
    end

    it "uses the shared web-fetch User-Agent for deep fetches" do
      retriever.retrieve(query: "test")

      expect(
        a_request(:get, "https://example.com/1").with(
          headers: { "User-Agent" => Homunculus::Tools::WebFetch::DEFAULT_USER_AGENT }
        )
      ).to have_been_made
    end
  end
end
