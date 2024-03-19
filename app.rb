# frozen_string_literal: true

# app.rb is a 'classic' [Sinatra](https://sinatrarb.com) application that provides an HTTP entry point for
# OpenArgoBridge.
#
# While useful for local development, we'll need a way for Argo Notifications to send event notifications
# to it, such as by using [ngrok](https://ngrok.com/)

require 'rubygems'
require 'bundler/setup'

# Add 'lib' to the load path so we can `require` local files as if they were gems
lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'argo_bridge'
require 'json'
require 'logger'
require 'sinatra'

####################
# HTTP status codes
HTTP_NO_CONTENT = 204
HTTP_NOT_FOUND  = 404
HTTP_INTERNAL_SERVER_ERROR = 500

# See values.yaml for the `CRASH_ON_STARTUP` environment variable setting
if ENV['CRASH_ON_STARTUP'] == 'true'
  puts "$CRASH_ON_STARTUP is set to 'true', so crashing on startup..."
  5.downto(1) do |i|
    puts "Crashing in #{i}..."
    sleep 1
  end
  puts 'Bye bye!'
  exit 1
end

LOGGING_BLACKLIST = ['/version', '/metrics'].freeze

# See https://stackoverflow.com/questions/10595938/remove-default-route-logging-in-sinatra-app
class FilteredCommonLogger < Rack::CommonLogger
  def call(env)
    if filter_log(env)
      # default CommonLogger behaviour: log and move on
      super
    else
      # pass request to next component without logging
      @app.call(env)
    end
  end

  # return true if request should be logged
  def filter_log(env)
    !LOGGING_BLACKLIST.include?(env['PATH_INFO'])
  end
end

# The 'singleton' (as far as this Sinatra app is concerned) instance of ArgoBridge
puts "$ARGO_BRIDGE_LOGGING_LEVEL: #{ENV.fetch('ARGO_BRIDGE_LOGGING_LEVEL', '<not set>')}"
ARGO_BRIDGE = ArgoBridge.new

configure do
  set :environment, :development
  set :logging, false
  use FilteredCommonLogger
end

# Accept any HTTP POST requests at the 'root' level. Reads the request body and extracts the request headers from
# request.env, then calls ArgoBridge
post '/*' do
  logger.info("POST #{request.path} from #{request.env['REMOTE_ADDR']}")
  body = request.body.read
  headers = extract_headers(request)

  ARGO_BRIDGE.handle(headers, body)
end

# Use this for the analysis check
get '/check' do
  # Set the following environment variable to "true" or "1" to cause the AnalysisRun to fail 100% of the time, or
  # set it "0.5" to fail 50% of the time, or unset it or set it to "0" to always succeed
  check_fail = ENV.fetch('CHECK_FAIL', nil)
  return HTTP_NO_CONTENT if check_fail.nil? || check_fail == '' || check_fail == '0' # always succeed

  return HTTP_INTERNAL_SERVER_ERROR if %w[true 1].include?(check_fail) # always fail

  failure_rate = check_fail.to_f

  return HTTP_NO_CONTENT if failure_rate.zero?

  rand < failure_rate ? HTTP_INTERNAL_SERVER_ERROR : HTTP_NO_CONTENT # succeed if failure_rate is 0, of if rand < failure_rate
end

# Return the current version of Argo Bridge
get '/version' do
  "#{ArgoBridge::VERSION}\n"
end

# Return the GC stats
get '/metrics' do
  GC.stat.to_json
end

# Accept any HTTP GET request and just log it, for troubleshooting and monitoring purposes, but return 404 Not Found
get '/' do
  logger.debug("GET / from #{request.env['REMOTE_ADDR']}")
  headers = extract_headers(request)
  headers.each do |k, v|
    logger.debug("#{k.inspect}: #{v}")
  end

  HTTP_NOT_FOUND
end

# Mimics how AWS Lambda forwards HTTP headers in the event. It examines all key + value pairs in the given request.env,
# finds those that start with `HTTP_` (which indicates it's a request header), then converts the remainder of the name
# to lowercase.
#
# @param request [Sinatra::Request] the Sinatra request
# @return [Hash] a hash of HTTP headers
def extract_headers(request)
  request.env.filter_map do |k, v|
    # if key starts_with('HTTP_'), discard the 'HTTP_', then convert to lowercase strings
    # otherswise, skip this key+value pair
    [k[5..].downcase, v] if k.start_with?('HTTP_')
  end.to_h
end
