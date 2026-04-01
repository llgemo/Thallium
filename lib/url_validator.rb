# frozen_string_literal: true

require 'uri'
require 'resolv'
require 'ipaddr'

# Validates and sanitises proxy target URLs.
# Blocks SSRF vectors: loopback, link-local, private ranges, file://, etc.
module UrlValidator
  extend self

  ALLOWED_SCHEMES = %w[http https].freeze

  # RFC 1918 / loopback / link-local / multicast ranges
  PRIVATE_RANGES = [
    IPAddr.new('0.0.0.0/8'),
    IPAddr.new('10.0.0.0/8'),
    IPAddr.new('100.64.0.0/10'),   # carrier-grade NAT
    IPAddr.new('127.0.0.0/8'),     # loopback
    IPAddr.new('169.254.0.0/16'),  # link-local
    IPAddr.new('172.16.0.0/12'),
    IPAddr.new('192.0.0.0/24'),
    IPAddr.new('192.168.0.0/16'),
    IPAddr.new('198.18.0.0/15'),
    IPAddr.new('198.51.100.0/24'),
    IPAddr.new('203.0.113.0/24'),
    IPAddr.new('224.0.0.0/4'),     # multicast
    IPAddr.new('240.0.0.0/4'),     # reserved
    IPAddr.new('255.255.255.255/32'),
    IPAddr.new('::1/128'),         # IPv6 loopback
    IPAddr.new('fc00::/7'),        # IPv6 unique local
    IPAddr.new('fe80::/10'),       # IPv6 link-local
  ].freeze

  # Hostnames we explicitly block
  BLOCKED_HOSTS = %w[
    localhost metadata.google.internal
    169.254.169.254
  ].freeze

  def valid?(url)
    return false if url.nil? || url.strip.empty?

    uri = URI.parse(url.strip)
    return false unless ALLOWED_SCHEMES.include?(uri.scheme&.downcase)
    return false if uri.host.nil? || uri.host.strip.empty?

    host = uri.host.downcase.sub(/\.$/, '') # strip trailing dot
    return false if BLOCKED_HOSTS.include?(host)
    return false if private_host?(host)

    true
  rescue URI::InvalidURIError
    false
  end

  private

  def private_host?(host)
    # Check raw IP
    begin
      addr = IPAddr.new(host)
      return private_ip?(addr)
    rescue IPAddr::InvalidAddressError
      # not a bare IP; fall through to DNS
    end

    # Resolve hostname and check each returned IP
    ips = Resolv.getaddresses(host)
    return true if ips.empty? # unresolvable — block it

    ips.any? do |ip_str|
      begin
        private_ip?(IPAddr.new(ip_str))
      rescue IPAddr::InvalidAddressError
        false
      end
    end
  rescue Resolv::ResolvError
    true # can't resolve — block
  end

  def private_ip?(addr)
    PRIVATE_RANGES.any? { |range| range.include?(addr) }
  end
end
