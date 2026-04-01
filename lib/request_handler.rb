# frozen_string_literal: true

require 'net/http'
require 'net/https'
require 'uri'
require 'zlib'
require 'stringio'
require_relative 'html_rewriter'
require_relative 'session_manager'

class RequestHandler
  class BlockedError  < StandardError; end
  class TimeoutError  < StandardError; end

  FOLLOW_REDIRECTS_MAX = 5
  CONNECT_TIMEOUT      = 10
  READ_TIMEOUT         = 20

  # Headers we strip from the upstream response before forwarding
  HOP_BY_HOP_HEADERS = %w[
    transfer-encoding connection keep-alive proxy-authenticate
    proxy-authorization te trailers upgrade content-encoding
  ].freeze

  # Headers we inject into outbound requests to look like a real browser
  BROWSER_HEADERS = {
    'User-Agent'      => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ' \
                         'AppleWebKit/537.36 (KHTML, like Gecko) ' \
                         'Chrome/124.0.0.0 Safari/537.36',
    'Accept'          => 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language' => 'en-US,en;q=0.9',
    'Accept-Encoding' => 'gzip, deflate',
    'Cache-Control'   => 'no-cache',
    'Pragma'          => 'no-cache'
  }.freeze

  def initialize(target_url, options = {}, session_id = nil)
    @target_url = target_url
    @options    = options
    @session_id = session_id
    @cookies    = SessionManager.cookies_for(session_id, target_url)
  end

  def fetch
    uri      = parse_uri(@target_url)
    response = follow_redirects(uri)
    body     = decode_body(response)
    ct       = response['content-type'].to_s

    # Rewrite HTML so all links/assets go through the proxy
    if ct.include?('text/html')
      body = HtmlRewriter.rewrite(body, uri.to_s)
    end

    # Persist any Set-Cookie from the upstream
    if response['set-cookie']
      SessionManager.store_cookies(@session_id, uri.to_s, response.get_fields('set-cookie') || [])
    end

    {
      status:       response.code.to_i,
      content_type: sanitize_content_type(ct),
      body:         body
    }
  end

  private

  def parse_uri(url)
    URI.parse(url)
  rescue URI::InvalidURIError
    raise ArgumentError, "Malformed URL: #{url}"
  end

  def follow_redirects(uri, hops = 0)
    raise BlockedError, 'Too many redirects' if hops > FOLLOW_REDIRECTS_MAX

    response = make_request(uri)

    if %w[301 302 303 307 308].include?(response.code)
      location = response['location']
      raise BlockedError, 'Redirect loop detected' if location.nil?

      new_uri = resolve_redirect(uri, location)
      follow_redirects(new_uri, hops + 1)
    else
      response
    end
  end

  def make_request(uri)
    http = build_http(uri)

    req = Net::HTTP::Get.new(uri.request_uri)
    BROWSER_HEADERS.each { |k, v| req[k] = v }
    req['Host']   = uri.host
    req['Cookie'] = @cookies if @cookies && !@cookies.empty?
    req['Referer'] = @options['referer'] if @options['referer']

    http.request(req)
  rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ETIMEDOUT
    raise TimeoutError
  rescue => e
    raise "HTTP request failed: #{e.message}"
  end

  def build_http(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = CONNECT_TIMEOUT
    http.read_timeout = READ_TIMEOUT

    if uri.scheme == 'https'
      http.use_ssl     = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    end

    http
  end

  def resolve_redirect(base_uri, location)
    if location.start_with?('http://', 'https://')
      URI.parse(location)
    else
      URI.join(base_uri.to_s, location)
    end
  end

  def decode_body(response)
    raw = response.body.to_s
    encoding = response['content-encoding'].to_s.downcase

    case encoding
    when 'gzip'
      gz = Zlib::GzipReader.new(StringIO.new(raw))
      gz.read
    when 'deflate'
      Zlib::Inflate.inflate(raw) rescue raw
    else
      raw
    end
  rescue => e
    raw
  end

  def sanitize_content_type(ct)
    # Never forward content-disposition that would force download of HTML
    return 'text/html; charset=utf-8' if ct.empty?
    ct.split(';').first.strip
  end
end
