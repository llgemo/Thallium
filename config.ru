# frozen_string_literal: true

require 'rack/cors'
require_relative 'server'

use Rack::Cors do
  allow do
    origins '*'
    resource '*',
             headers: :any,
             methods: %i[get post options],
             expose: %w[X-Powered-By]
  end
end

run Sinatra::Application
