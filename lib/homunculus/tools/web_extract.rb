# frozen_string_literal: true

require "uri"
require "nokogiri"
require "oj"

module Homunculus
  module Tools
    class WebExtract < Base
      tool_name "web_extract"
      description <<~DESC.strip
        Extract structured data from a web page using CSS selectors.
        Returns a JSON object mapping selector names to extracted text values.
        Dramatically reduces raw HTML in context compared to web_fetch.
        Network access is required. Only HTTP/HTTPS URLs are allowed.
      DESC
      trust_level :mixed
      requires_confirmation true

      parameter :url, type: :string, description: "URL to fetch (must be http:// or https://)"
      parameter :selectors, type: :string,
                            description: 'JSON object mapping names to CSS selectors, e.g. {"title": "h1", "prices": ".price"}'
      parameter :format, type: :string, description: "Output format: 'json' (default) or 'table'",
                         required: false, enum: %w[json table]

      MAX_FIELD_SIZE = 1024
      MAX_SELECTORS = 20

      def initialize(config: nil, web_fetch: nil)
        super()
        @config = config
        @web_fetch = web_fetch
      end

      def execute(arguments:, session:)
        url = arguments[:url]
        return Result.fail("Missing required parameter: url") unless url

        selectors_json = arguments[:selectors]
        return Result.fail("Missing required parameter: selectors") unless selectors_json

        selectors = parse_selectors(selectors_json)
        return Result.fail(selectors) if selectors.is_a?(String)

        format = arguments.fetch(:format, "json")

        # Fetch the page HTML using a WebFetch instance (reuses SSRF/rate-limit infra)
        fetcher = @web_fetch || WebFetch.new(config: @config)
        fetch_result = fetcher.execute(arguments: { url: url, mode: "raw" }, session: session)
        return Result.fail("Fetch failed: #{fetch_result.error}") unless fetch_result.success

        html = fetch_result.output
        extracted = extract_with_selectors(html, selectors)

        output = format == "table" ? format_as_table(extracted) : Oj.dump(extracted, mode: :compat)
        Result.ok(output, url: url, selector_count: selectors.size)
      rescue StandardError => e
        Result.fail("Web extract error: #{e.message}")
      end

      private

      def parse_selectors(json_str)
        parsed = Oj.load(json_str)
        return "Selectors must be a JSON object" unless parsed.is_a?(Hash)
        return "Too many selectors (max #{MAX_SELECTORS})" if parsed.size > MAX_SELECTORS
        return "Selectors cannot be empty" if parsed.empty?

        parsed.transform_keys(&:to_s)
      rescue StandardError => e
        "Invalid selectors JSON: #{e.message}"
      end

      def extract_with_selectors(html, selectors)
        doc = Nokogiri::HTML(html)

        selectors.each_with_object({}) do |(name, css), result|
          elements = doc.css(css)
          values = elements.map { |el| sanitize_value(el.text) }
          result[name] = values.size == 1 ? values.first : values
        end
      end

      def sanitize_value(text)
        cleaned = text.to_s.gsub(/\s+/, " ").strip
        cleaned = cleaned[0...MAX_FIELD_SIZE] if cleaned.length > MAX_FIELD_SIZE
        Security::ContentSanitizer.filter_injections(cleaned)
      end

      def format_as_table(data)
        lines = data.map do |name, value|
          formatted = case value
                      when Array then value.join(", ")
                      else value.to_s
                      end
          "#{name}: #{formatted}"
        end
        lines.join("\n")
      end
    end
  end
end
