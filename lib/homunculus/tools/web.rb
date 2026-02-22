# frozen_string_literal: true

require "uri"
require "ipaddr"
require "nokogiri"

module Homunculus
  module Tools
    class WebFetch < Base
      tool_name "web_fetch"
      description <<~DESC.strip
        Fetch the content of a web page or API endpoint.
        Returns the page text (HTML stripped) or raw response body.
        Network access is required. Only HTTP/HTTPS URLs are allowed.
        Use mode 'extract_text' to strip HTML and get readable text.
        Use mode 'raw' to get the raw response body (for APIs).
        Supports GET (default), POST, and PUT methods.
        Optionally pass a session_id to persist cookies across requests.
      DESC
      trust_level :mixed
      requires_confirmation true

      parameter :url, type: :string, description: "URL to fetch (must be http:// or https://)"
      parameter :mode, type: :string, description: "Response mode: 'extract_text' (default) or 'raw'",
                       required: false, enum: %w[extract_text raw]
      parameter :headers, type: :string, description: "Optional HTTP headers as JSON string", required: false
      parameter :method, type: :string, description: "HTTP method: GET (default), POST, or PUT",
                         required: false, enum: %w[GET POST PUT]
      parameter :body, type: :string, description: "Request body for POST/PUT (max 100KB)", required: false
      parameter :content_type, type: :string, description: "Content-Type header (default: application/json)",
                               required: false
      parameter :session_id, type: :string, description: "Session ID for cookie persistence across requests",
                             required: false

      MAX_RESPONSE_SIZE = 500_000 # 500KB
      MAX_BODY_SIZE = 102_400 # 100KB
      REQUEST_TIMEOUT = 30
      MAX_REQUESTS_PER_MINUTE = 10
      ALLOWED_METHODS = %w[GET POST PUT].freeze

      # Private IP ranges for SSRF protection
      BLOCKED_IP_RANGES = [
        IPAddr.new("10.0.0.0/8"),
        IPAddr.new("172.16.0.0/12"),
        IPAddr.new("192.168.0.0/16"),
        IPAddr.new("127.0.0.0/8"),
        IPAddr.new("169.254.0.0/16"),
        IPAddr.new("0.0.0.0/8"),
        IPAddr.new("::1/128"),
        IPAddr.new("fc00::/7"),
        IPAddr.new("fe80::/10")
      ].freeze

      BLOCKED_SCHEMES = %w[file ftp gopher data javascript].freeze

      def initialize(config: nil, session_store: nil)
        super()
        @config = config
        @session_store = session_store || WebSessionStore.new
        @request_timestamps = []
        @mutex = Mutex.new
      end

      def execute(arguments:, session:)
        url_str = arguments[:url]
        return Result.fail("Missing required parameter: url") unless url_str

        http_method = (arguments[:method] || "GET").upcase
        return Result.fail("Unsupported HTTP method: #{http_method}") unless ALLOWED_METHODS.include?(http_method)

        mode = arguments.fetch(:mode, "extract_text")
        body = arguments[:body]
        content_type = arguments[:content_type] || "application/json"
        web_session_id = arguments[:session_id]

        # Validate body constraints
        if body
          return Result.fail("Request body is only allowed with POST or PUT") if http_method == "GET"
          return Result.fail("Request body too large (max #{MAX_BODY_SIZE} bytes)") if body.bytesize > MAX_BODY_SIZE
        end

        # Parse and validate URL
        uri = parse_and_validate_url(url_str)
        return Result.fail(uri) if uri.is_a?(String) # Error message

        # SSRF protection: check resolved IP
        ssrf_check = check_ssrf(uri)
        return Result.fail(ssrf_check) if ssrf_check

        # Rate limiting
        rate_check = check_rate_limit
        return Result.fail(rate_check) if rate_check

        # Parse optional headers
        extra_headers = parse_headers(arguments[:headers])

        # Perform the fetch
        fetch_url(uri, mode:, extra_headers:, http_method:, body:, content_type:,
                       web_session_id:)
      rescue StandardError => e
        Result.fail("Web fetch error: #{e.message}")
      end

      private

      def parse_and_validate_url(url_str)
        # Pre-check for known bad schemes before URI.parse (which may choke on them)
        scheme = url_str.to_s.split(":", 2).first&.downcase
        return "Invalid URL scheme: #{scheme}. Only http:// and https:// are allowed." if BLOCKED_SCHEMES.include?(scheme)

        uri = URI.parse(url_str)

        unless %w[http https].include?(uri.scheme&.downcase)
          return "Invalid URL scheme: #{uri.scheme}. Only http:// and https:// are allowed."
        end

        return "Invalid URL: missing host" unless uri.host && !uri.host.empty?

        uri
      rescue URI::InvalidURIError => e
        "Invalid URL: #{e.message}"
      end

      def check_ssrf(uri)
        # Block dangerous schemes in any redirect target
        return "Blocked URL scheme: #{uri.scheme}" if BLOCKED_SCHEMES.include?(uri.scheme&.downcase)

        # Resolve hostname to IP and check against blocked ranges
        begin
          addresses = Addrinfo.getaddrinfo(uri.host, nil, nil, :STREAM)
          addresses.each do |addr|
            ip = IPAddr.new(addr.ip_address)
            return "Blocked: URL resolves to private/internal IP address" if BLOCKED_IP_RANGES.any? { |range| range.include?(ip) }
          end
        rescue SocketError => e
          return "DNS resolution failed for #{uri.host}: #{e.message}"
        end

        nil # No SSRF issue
      end

      def check_rate_limit
        @mutex.synchronize do
          now = Time.now
          # Remove timestamps older than 60 seconds
          @request_timestamps.reject! { |ts| now - ts > 60 }

          if @request_timestamps.size >= MAX_REQUESTS_PER_MINUTE
            return "Rate limit exceeded: max #{MAX_REQUESTS_PER_MINUTE} requests per minute"
          end

          @request_timestamps << now
        end

        nil # Rate limit OK
      end

      def parse_headers(headers_json)
        return {} unless headers_json

        Oj.load(headers_json)
      rescue StandardError
        {}
      end

      def fetch_url(uri, mode:, extra_headers:, http_method: "GET", body: nil,
                    content_type: "application/json", web_session_id: nil)
        headers = {
          "User-Agent" => "Homunculus/1.0 (bot)",
          "Accept" => mode == "raw" ? "*/*" : "text/html,application/xhtml+xml,*/*"
        }
        headers["Content-Type"] = content_type if body
        headers.merge!(extra_headers)

        client = build_http_client(headers, http_method:, web_session_id:)
        response = dispatch_request(client, uri, http_method, body)

        unless response.respond_to?(:status)
          msg = response.respond_to?(:error) && response.error ? response.error.message : "connection failed"
          return Result.fail("HTTP error: #{msg}")
        end

        return Result.fail("HTTP #{response.status}: #{response.body.to_s[0..200]}") unless response.status == 200

        store_response_cookies(response)

        response_body = response.body.to_s
        response_body = response_body[0...MAX_RESPONSE_SIZE] if response_body.bytesize > MAX_RESPONSE_SIZE

        content = if mode == "extract_text"
                    extract_text(response_body)
                  else
                    response_body
                  end

        Result.ok(content, url: uri.to_s, status: response.status, size: response_body.bytesize, method: http_method)
      rescue HTTPX::TimeoutError
        Result.fail("Request timed out after #{REQUEST_TIMEOUT}s")
      rescue HTTPX::Error => e
        Result.fail("HTTP error: #{e.message}")
      end

      def build_http_client(headers, http_method:, web_session_id:)
        client = HTTPX

        # Only follow redirects for GET requests
        client = client.plugin(:follow_redirects, max_redirects: 5) if http_method == "GET"

        # Cookie persistence via session store
        if web_session_id
          cookies = @session_store.get_or_create(web_session_id)
          headers = headers.merge("Cookie" => format_cookies(cookies)) unless cookies.empty?
          @current_session_cookies = cookies
        else
          @current_session_cookies = nil
        end

        client = client.with(
          timeout: { operation_timeout: REQUEST_TIMEOUT },
          headers:
        )

        if http_method == "GET"
          client = client.with(
            follow_redirects_callbacks: [method(:validate_redirect)]
          )
        end

        client
      end

      def format_cookies(cookies)
        cookies.map { |k, v| "#{k}=#{v}" }.join("; ")
      end

      def store_response_cookies(response)
        return unless @current_session_cookies && response.respond_to?(:headers)

        set_cookies = Array(response.headers["set-cookie"])
        set_cookies.each do |cookie_str|
          name_value = cookie_str.split(";").first&.strip
          next unless name_value

          name, value = name_value.split("=", 2)
          @current_session_cookies[name] = value if name && value
        end
      end

      def dispatch_request(client, uri, http_method, body)
        case http_method
        when "POST"
          client.post(uri.to_s, body: body)
        when "PUT"
          client.put(uri.to_s, body: body)
        else
          client.get(uri.to_s)
        end
      end

      def validate_redirect(response)
        location = response.headers["location"]
        return unless location

        redirect_uri = URI.parse(location)

        # Block redirects to dangerous schemes
        if BLOCKED_SCHEMES.include?(redirect_uri.scheme&.downcase)
          raise HTTPX::Error, "Blocked redirect to #{redirect_uri.scheme}:// URL"
        end

        # Block redirects to internal IPs
        ssrf_result = check_ssrf(redirect_uri)
        raise HTTPX::Error, ssrf_result if ssrf_result
      rescue URI::InvalidURIError
        raise HTTPX::Error, "Invalid redirect URL"
      end

      def extract_text(html)
        return html unless defined?(Nokogiri)

        doc = Nokogiri::HTML(html)

        # Remove script, style, and other non-content elements
        doc.css("script, style, noscript, iframe, object, embed, svg, nav, footer, header").remove

        # Extract text content
        text = doc.css("body").text
        text = doc.text if text.strip.empty?

        # Clean up whitespace: collapse multiple newlines/spaces
        text
          .gsub(/[ \t]+/, " ")
          .gsub(/\n{3,}/, "\n\n")
          .strip
      end
    end
  end
end
