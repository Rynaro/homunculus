# frozen_string_literal: true

require "spec_helper"

RSpec.describe Homunculus::Tools::WebFetch do
  subject(:tool) { described_class.new }

  let(:session) { Homunculus::Session.new }

  it "has correct metadata" do
    expect(tool.name).to eq("web_fetch")
    expect(tool.requires_confirmation).to be true
    expect(tool.trust_level).to eq(:mixed)
  end

  it "fails when url is missing" do
    result = tool.execute(arguments: {}, session:)

    expect(result.success).to be false
    expect(result.error).to include("Missing required parameter: url")
  end

  describe "URL validation" do
    it "rejects file:// URLs" do
      result = tool.execute(arguments: { url: "file:///etc/passwd" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Invalid URL scheme")
    end

    it "rejects ftp:// URLs" do
      result = tool.execute(arguments: { url: "ftp://evil.com/file" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Invalid URL scheme")
    end

    it "rejects gopher:// URLs" do
      result = tool.execute(arguments: { url: "gopher://evil.com" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Invalid URL scheme")
    end

    it "rejects data: URLs" do
      result = tool.execute(arguments: { url: "data:text/html,<h1>evil</h1>" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Invalid URL scheme")
    end

    it "rejects URLs without host" do
      result = tool.execute(arguments: { url: "http://" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("missing host")
    end

    it "rejects invalid URLs" do
      result = tool.execute(arguments: { url: "not a url at all" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Invalid URL")
    end
  end

  describe "SSRF protection" do
    it "blocks requests to localhost (127.0.0.1)" do
      allow(Addrinfo).to receive(:getaddrinfo).and_return(
        [instance_double(Addrinfo, ip_address: "127.0.0.1")]
      )

      result = tool.execute(arguments: { url: "http://localhost/admin" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("private/internal IP")
    end

    it "blocks requests to 10.x.x.x range" do
      allow(Addrinfo).to receive(:getaddrinfo).and_return(
        [instance_double(Addrinfo, ip_address: "10.0.0.1")]
      )

      result = tool.execute(arguments: { url: "http://internal.corp.com" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("private/internal IP")
    end

    it "blocks requests to 172.16.x.x range" do
      allow(Addrinfo).to receive(:getaddrinfo).and_return(
        [instance_double(Addrinfo, ip_address: "172.16.0.1")]
      )

      result = tool.execute(arguments: { url: "http://docker-service.local" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("private/internal IP")
    end

    it "blocks requests to 192.168.x.x range" do
      allow(Addrinfo).to receive(:getaddrinfo).and_return(
        [instance_double(Addrinfo, ip_address: "192.168.1.1")]
      )

      result = tool.execute(arguments: { url: "http://router.local" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("private/internal IP")
    end

    it "blocks requests to link-local addresses" do
      allow(Addrinfo).to receive(:getaddrinfo).and_return(
        [instance_double(Addrinfo, ip_address: "169.254.169.254")]
      )

      result = tool.execute(arguments: { url: "http://metadata.google.internal" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("private/internal IP")
    end

    it "blocks requests to IPv6 loopback" do
      allow(Addrinfo).to receive(:getaddrinfo).and_return(
        [instance_double(Addrinfo, ip_address: "::1")]
      )

      result = tool.execute(arguments: { url: "http://[::1]/admin" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("private/internal IP")
    end

    it "allows requests to public IPs" do
      allow(Addrinfo).to receive(:getaddrinfo).and_return(
        [instance_double(Addrinfo, ip_address: "93.184.216.34")]
      )

      # Mock the actual HTTP request
      response = instance_double(HTTPX::Response, status: 200, body: double(to_s: "<html><body>Hello</body></html>"))
      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive_messages(get: response, with: http_client)
      allow(HTTPX).to receive(:plugin).and_return(http_client)

      result = tool.execute(arguments: { url: "http://example.com" }, session:)

      expect(result.success).to be true
    end
  end

  describe "rate limiting" do
    it "allows requests within rate limit" do
      allow(Addrinfo).to receive(:getaddrinfo).and_return(
        [instance_double(Addrinfo, ip_address: "93.184.216.34")]
      )

      response = instance_double(HTTPX::Response, status: 200, body: double(to_s: "ok"))
      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive_messages(get: response, with: http_client)
      allow(HTTPX).to receive(:plugin).and_return(http_client)

      # Should succeed for first 10 requests
      3.times do
        result = tool.execute(arguments: { url: "http://example.com", mode: "raw" }, session:)
        expect(result.success).to be true
      end
    end

    it "rejects requests exceeding rate limit" do
      allow(Addrinfo).to receive(:getaddrinfo).and_return(
        [instance_double(Addrinfo, ip_address: "93.184.216.34")]
      )

      response = instance_double(HTTPX::Response, status: 200, body: double(to_s: "ok"))
      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive_messages(get: response, with: http_client)
      allow(HTTPX).to receive(:plugin).and_return(http_client)

      # Exhaust rate limit
      10.times do
        tool.execute(arguments: { url: "http://example.com", mode: "raw" }, session:)
      end

      # 11th request should be rate limited
      result = tool.execute(arguments: { url: "http://example.com", mode: "raw" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Rate limit exceeded")
    end
  end

  describe "HTML extraction" do
    it "strips HTML tags and returns text content" do
      allow(Addrinfo).to receive(:getaddrinfo).and_return(
        [instance_double(Addrinfo, ip_address: "93.184.216.34")]
      )

      html = <<~HTML
        <html>
        <head><title>Test</title></head>
        <body>
          <script>alert('evil')</script>
          <style>.x { color: red }</style>
          <h1>Hello World</h1>
          <p>This is a test page.</p>
        </body>
        </html>
      HTML

      response = instance_double(HTTPX::Response, status: 200, body: double(to_s: html))
      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive_messages(get: response, with: http_client)
      allow(HTTPX).to receive(:plugin).and_return(http_client)

      result = tool.execute(arguments: { url: "http://example.com" }, session:)

      expect(result.success).to be true
      expect(result.output).to include("Hello World")
      expect(result.output).to include("This is a test page")
      expect(result.output).not_to include("<script>")
      expect(result.output).not_to include("alert")
      expect(result.output).not_to include("color: red")
    end
  end

  describe "DNS resolution failure" do
    it "reports DNS failures clearly" do
      allow(Addrinfo).to receive(:getaddrinfo).and_raise(
        SocketError.new("getaddrinfo: nodename nor servname provided")
      )

      result = tool.execute(arguments: { url: "http://nonexistent.invalid" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("DNS resolution failed")
    end
  end

  describe "HTTP method support" do
    before do
      allow(Addrinfo).to receive(:getaddrinfo).and_return(
        [instance_double(Addrinfo, ip_address: "93.184.216.34")]
      )
    end

    it "rejects unsupported HTTP methods" do
      result = tool.execute(arguments: { url: "http://example.com", method: "DELETE" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("Unsupported HTTP method")
    end

    it "rejects body with GET method" do
      result = tool.execute(arguments: { url: "http://example.com", method: "GET", body: "data" }, session:)

      expect(result.success).to be false
      expect(result.error).to include("only allowed with POST or PUT")
    end

    it "rejects body exceeding max size" do
      large_body = "x" * 200_000
      result = tool.execute(arguments: { url: "http://example.com", method: "POST", body: large_body }, session:)

      expect(result.success).to be false
      expect(result.error).to include("body too large")
    end

    it "executes POST requests" do
      response = instance_double(HTTPX::Response, status: 200, body: double(to_s: '{"ok":true}'))
      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive_messages(post: response, with: http_client)
      allow(HTTPX).to receive(:with).and_return(http_client)

      result = tool.execute(
        arguments: { url: "http://api.example.com/data", method: "POST", body: '{"key":"value"}', mode: "raw" },
        session:
      )

      expect(result.success).to be true
      expect(result.output).to eq('{"ok":true}')
      expect(result.metadata[:method]).to eq("POST")
    end

    it "executes PUT requests" do
      response = instance_double(HTTPX::Response, status: 200, body: double(to_s: '{"updated":true}'))
      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive_messages(put: response, with: http_client)
      allow(HTTPX).to receive(:with).and_return(http_client)

      result = tool.execute(
        arguments: { url: "http://api.example.com/data/1", method: "PUT", body: '{"key":"new"}', mode: "raw" },
        session:
      )

      expect(result.success).to be true
      expect(result.output).to eq('{"updated":true}')
    end

    it "defaults to GET when method not specified" do
      response = instance_double(HTTPX::Response, status: 200, body: double(to_s: "ok"))
      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive_messages(get: response, with: http_client)
      allow(HTTPX).to receive(:plugin).and_return(http_client)

      result = tool.execute(arguments: { url: "http://example.com", mode: "raw" }, session:)

      expect(result.success).to be true
    end
  end

  describe "session cookie persistence" do
    let(:session_store) { Homunculus::Tools::WebSessionStore.new }
    let(:tool_with_store) { described_class.new(session_store: session_store) }

    before do
      allow(Addrinfo).to receive(:getaddrinfo).and_return(
        [instance_double(Addrinfo, ip_address: "93.184.216.34")]
      )
    end

    it "creates a session when session_id is provided" do
      response = instance_double(HTTPX::Response, status: 200, body: double(to_s: "ok"))
      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive_messages(get: response, with: http_client)
      allow(HTTPX).to receive(:plugin).and_return(http_client)

      tool_with_store.execute(
        arguments: { url: "http://example.com", mode: "raw", session_id: "my-session" },
        session:
      )

      expect(session_store.active_count).to eq(1)
    end

    it "works without session_id (stateless mode)" do
      response = instance_double(HTTPX::Response, status: 200, body: double(to_s: "ok"))
      http_client = instance_double(HTTPX::Session)
      allow(http_client).to receive_messages(get: response, with: http_client)
      allow(HTTPX).to receive(:plugin).and_return(http_client)

      result = tool_with_store.execute(
        arguments: { url: "http://example.com", mode: "raw" },
        session:
      )

      expect(result.success).to be true
      expect(session_store.active_count).to eq(0)
    end
  end
end
