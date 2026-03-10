# frozen_string_literal: true

require "uri"
require "ipaddr"
require "nokogiri"

require_relative "web_classification"

module Homunculus
  module Tools
    class WebFetch < Base
      tool_name "web_fetch"
      description <<~DESC.strip
        Fetch content from a specific web page or endpoint when you already know the URL.
        If `web_research` is available in this session, prefer it first for factual lookups like weather, news, prices, or scores.
        Do not guess API endpoints or call APIs unless you know the required credentials are configured.
        If this tool reports blocked_bot, js_required, timeout, or rate_limited, use web_research as fallback only when that tool is available.
        If it reports auth_required, inform the user and ask for access, credentials, or a different public URL.
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

      DEFAULT_USER_AGENT = "Mozilla/5.0 (compatible; Homunculus/1.0; +https://github.com/rynaro/homunculus)"

      def initialize(config: nil, session_store: nil)
        super()
        @config = config
        @session_store = session_store || WebSessionStore.new
        @request_timestamps = []
        @mutex = Mutex.new
      end

      def user_agent
        return DEFAULT_USER_AGENT unless @config
        return DEFAULT_USER_AGENT unless @config.respond_to?(:tools)

        web_cfg = @config.tools.respond_to?(:web) ? @config.tools.web : nil
        return DEFAULT_USER_AGENT unless web_cfg
        return DEFAULT_USER_AGENT if web_cfg.user_agent_override.to_s.strip.empty?

        web_cfg.user_agent_override.to_s.strip
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
      rescue HTTPX::TimeoutError, HTTPX::RequestTimeoutError, HTTPX::ReadTimeoutError,
             HTTPX::OperationTimeoutError, HTTPX::ConnectTimeoutError => e
        Result.fail(classification_message(WebClassification::TIMEOUT, prefix: "Web fetch error: #{e.message}"),
                    fetch_mode: arguments.fetch(:mode, "extract_text"),
                    failure_reason: WebClassification::TIMEOUT,
                    response_classification: WebClassification::TIMEOUT)
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
          "User-Agent" => user_agent,
          "Accept" => mode == "raw" ? "*/*" : "text/html,application/xhtml+xml,*/*"
        }
        headers["Content-Type"] = content_type if body
        headers.merge!(extra_headers)

        client = build_http_client(headers, http_method:, web_session_id:)
        response = dispatch_request(client, uri, http_method, body)

        return fail_connection_error(response, mode) unless response.respond_to?(:status)

        response_body = response.body.to_s
        classification = WebClassification.classify(status: response.status, body: response_body, timeout: false)

        non_ok = handle_non_ok_status(response, response_body, classification, mode)
        return non_ok if non_ok

        class_fail = handle_classification_failure(classification, mode)
        return class_fail if class_fail

        store_response_cookies(response)
        response_body = response_body[0...MAX_RESPONSE_SIZE] if response_body.bytesize > MAX_RESPONSE_SIZE
        content = mode == "extract_text" ? extract_text(response_body) : response_body

        Result.ok(content, url: uri.to_s, status: response.status, size: response_body.bytesize,
                           method: http_method, fetch_mode: mode, response_classification: WebClassification::SUCCESS)
      rescue HTTPX::TimeoutError
        Result.fail(classification_message(WebClassification::TIMEOUT,
                                           prefix: "Request timed out after #{REQUEST_TIMEOUT}s"),
                    fetch_mode: mode, failure_reason: WebClassification::TIMEOUT,
                    response_classification: WebClassification::TIMEOUT)
      rescue HTTPX::Error => e
        Result.fail(classification_message(WebClassification::BLOCKED_BOT, prefix: "HTTP error: #{e.message}"),
                    fetch_mode: mode, failure_reason: WebClassification::BLOCKED_BOT,
                    response_classification: "http_error")
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

      def fail_connection_error(response, mode)
        msg = response.respond_to?(:error) && response.error ? response.error.message : "connection failed"
        Result.fail(classification_message(WebClassification::BLOCKED_BOT, prefix: "HTTP error: #{msg}"),
                    fetch_mode: mode, failure_reason: WebClassification::BLOCKED_BOT,
                    response_classification: "connection_error")
      end

      def handle_non_ok_status(response, response_body, classification, mode)
        return nil if response.status == 200

        Result.fail(classification_message(classification[:failure_reason],
                                           prefix: "HTTP #{response.status}: #{response_body[0..200]}"),
                    fetch_mode: mode, failure_reason: classification[:failure_reason],
                    response_classification: classification[:response_classification])
      end

      def handle_classification_failure(classification, mode)
        return nil if classification[:failure_reason] == WebClassification::SUCCESS

        Result.fail(classification_message(classification[:failure_reason]),
                    fetch_mode: mode, failure_reason: classification[:failure_reason],
                    response_classification: classification[:response_classification])
      end

      def classification_message(failure_reason, prefix: nil)
        hint = case failure_reason
               when WebClassification::AUTH_REQUIRED
                 "Page requires authentication, login, a paywall, or CAPTCHA. " \
                 "Inform the user and ask for access, credentials, or a different public URL."
               when WebClassification::JS_REQUIRED
                 "Page needs JavaScript to load content. Try web_research instead."
               when WebClassification::TIMEOUT
                 "Request timed out. Try web_research instead."
               when WebClassification::RATE_LIMITED
                 "Site rate limited the request. Wait before retrying or use web_research."
               when WebClassification::BLOCKED_BOT
                 "Site blocked the request. Try web_research instead."
               else
                 "Fetch blocked or content unavailable (#{failure_reason}). Try web_research instead."
               end

        return hint unless prefix

        formatted_prefix = prefix.to_s.strip
        formatted_prefix = "#{formatted_prefix}." unless formatted_prefix.end_with?(".", "!", "?")
        "#{formatted_prefix} #{hint}"
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
