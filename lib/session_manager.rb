# frozen_string_literal: true

require 'uri'
require 'monitor'

# Stores per-session cookies so multi-step sites (login flows, etc.) work.
module SessionManager
  extend self

  EXPIRY_SECONDS = 3600 # 1 hour

  @store   = {}
  @monitor = Monitor.new
  @count   = 0

  # Return a Cookie header string for the given session + target host
  def cookies_for(session_id, url)
    return '' unless session_id

    host = host_from(url)
    @monitor.synchronize do
      cleanup!
      session = @store[session_id]
      return '' unless session

      pairs = (session[:cookies][host] || {}).map { |k, v| "#{k}=#{v}" }
      pairs.join('; ')
    end
  end

  # Persist Set-Cookie headers from a response
  def store_cookies(session_id, url, set_cookie_headers)
    return unless session_id && set_cookie_headers&.any?

    host = host_from(url)
    @monitor.synchronize do
      @store[session_id] ||= { cookies: {}, last_seen: Time.now }
      @store[session_id][:last_seen] = Time.now
      @store[session_id][:cookies][host] ||= {}

      set_cookie_headers.each do |header|
        name, value = parse_set_cookie(header)
        next unless name

        if value.nil?
          @store[session_id][:cookies][host].delete(name)
        else
          @store[session_id][:cookies][host][name] = value
        end
      end
    end
  end

  def active_count
    @monitor.synchronize { @store.size }
  end

  def total_requests
    @count
  end

  def increment_requests!
    @monitor.synchronize { @count += 1 }
  end

  private

  def host_from(url)
    URI.parse(url).host.to_s.downcase
  rescue
    url.to_s
  end

  def parse_set_cookie(header)
    # "name=value; Path=/; HttpOnly; Expires=..."
    first_part = header.split(';').first.to_s.strip
    eq_idx     = first_part.index('=')
    return [nil, nil] unless eq_idx

    name  = first_part[0...eq_idx].strip
    value = first_part[(eq_idx + 1)..].strip
    # A header like "name=; ..." means delete the cookie
    value = nil if value.empty?
    [name, value]
  end

  def cleanup!
    cutoff = Time.now - EXPIRY_SECONDS
    @store.delete_if { |_, v| v[:last_seen] < cutoff }
  end
end
