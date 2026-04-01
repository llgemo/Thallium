#!/usr/bin/env ruby
# frozen_string_literal: true

require 'sinatra'
require 'net/http'
require 'net/https'
require 'uri'
require 'nokogiri'
require 'json'
require 'base64'
require 'zlib'
require 'stringio'
require 'logger'
require_relative 'lib/request_handler'
require_relative 'lib/html_rewriter'
require_relative 'lib/session_manager'
require_relative 'lib/rate_limiter'
require_relative 'lib/url_validator'

configure do
  set :server, 'puma'
  set :port, ENV.fetch('PORT', 4567).to_i
  set :bind, '0.0.0.0'
  set :logging, true
  set :show_exceptions, false

  logger = Logger.new($stdout)
  logger.level = Logger::INFO
  set :logger, logger

  set :protection, except: [:frame_options, :json_csrf]
end

before do
  headers(
    'Access-Control-Allow-Origin'  => '*',
    'Access-Control-Allow-Methods' => 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers' => 'Content-Type, X-Requested-With',
    'X-Powered-By'                 => 'Thallium/1.0',
    'X-Content-Type-Options'       => 'nosniff'
  )
  halt 200 if request.request_method == 'OPTIONS'
end

error do |e|
  settings.logger.error "Unhandled error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
  content_type :json
  status 500
  JSON.generate({ error: 'Internal proxy error', message: e.message })
end

get '/health' do
  content_type :json
  JSON.generate({ status: 'ok', version: '1.0.0', name: 'Thallium' })
end

post '/api/proxy' do
  body_data = request.body.read
  params_in = JSON.parse(body_data) rescue {}

  target_url = params_in['url'].to_s.strip
  options    = params_in['options'] || {}

  unless UrlValidator.valid?(target_url)
    content_type :json
    halt 400, JSON.generate({ error: 'Invalid or blocked URL' })
  end

  client_ip = request.ip
  unless RateLimiter.allow?(client_ip)
    content_type :json
    halt 429, JSON.generate({ error: 'Rate limit exceeded. Please wait a moment.' })
  end

  session_id = request.cookies['thallium_session'] || SecureRandom.hex(16)
  handler    = RequestHandler.new(target_url, options, session_id)

  begin
    result = handler.fetch
    response.set_cookie('thallium_session', value: session_id, path: '/', http_only: true)
    content_type result[:content_type] || 'text/html'
    status result[:status] || 200
    result[:body]
  rescue RequestHandler::BlockedError => e
    content_type :json
    halt 403, JSON.generate({ error: e.message })
  rescue RequestHandler::TimeoutError
    content_type :json
    halt 504, JSON.generate({ error: 'Target server timed out' })
  rescue => e
    settings.logger.error "Proxy fetch error: #{e.message}"
    content_type :json
    halt 502, JSON.generate({ error: "Could not reach target: #{e.message}" })
  end
end

get '/proxy' do
  target_url = params['url'].to_s.strip

  unless UrlValidator.valid?(target_url)
    halt 400, 'Invalid or blocked URL'
  end

  client_ip = request.ip
  unless RateLimiter.allow?(client_ip)
    halt 429, 'Rate limit exceeded'
  end

  session_id = request.cookies['thallium_session'] || SecureRandom.hex(16)
  handler    = RequestHandler.new(target_url, {}, session_id)

  begin
    result = handler.fetch
    response.set_cookie('thallium_session', value: session_id, path: '/', http_only: true)
    content_type result[:content_type] || 'application/octet-stream'
    status result[:status] || 200
    result[:body]
  rescue => e
    halt 502, "Proxy error: #{e.message}"
  end
end

get '/api/info' do
  target_url = params['url'].to_s.strip
  unless UrlValidator.valid?(target_url)
    content_type :json
    halt 400, JSON.generate({ error: 'Invalid URL' })
  end

  begin
    uri = URI.parse(target_url)
    content_type :json
    JSON.generate(
      host:    uri.host,
      scheme:  uri.scheme,
      path:    uri.path,
      port:    uri.port,
      proxied: "/proxy?url=#{URI.encode_www_form_component(target_url)}"
    )
  rescue URI::InvalidURIError
    content_type :json
    halt 400, JSON.generate({ error: 'Malformed URL' })
  end
end

get '/api/stats' do
  content_type :json
  JSON.generate(
    requests_served: RateLimiter.total_requests,
    active_sessions: SessionManager.active_count,
    uptime_seconds:  (Time.now - START_TIME).to_i
  )
end

START_TIME = Time.now