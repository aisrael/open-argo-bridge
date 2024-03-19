# frozen_string_literal: true

require 'csv'
require 'date'
require 'github'
require 'json'
require 'logger'
require 'slack'
require 'yaml'

require_relative 'version'
require_relative 'argo_bridge/core'
require_relative 'argo_bridge/argo_rollouts_handler'
require_relative 'argo_bridge/argocd_handler'

# The ArgoBridge class contains the high-level methods needed perform its function. It is called by
# the handle() method in `handler.rb`, or by the `post '/*' do` block in `app.rb``.
#
# ArgoBridge uses instances of the {GitHub} and {Slack} classes as helpers or interfaces to
# abstract and encapsulate the details of their respective APIs.
class ArgoBridge
  VERSION = ARGO_BRIDGE_VERSION

  GITHUB_ORG_NAME = ENV.fetch('GITHUB_ORG_NAME')

  # The Slack channel to send  deployment notification messages to. Set using the `DEPLOYMENT_NOTIFICATIONS_CHANNEL_ID`
  # environment variable.
  DEPLOYMENT_NOTIFICATIONS_CHANNEL_ID = ENV.fetch('DEPLOYMENT_NOTIFICATIONS_CHANNEL_ID')

  # HTTP 204 No Content
  HTTP_NO_CONTENT = 204

  # HTTP 400 Bad Request
  HTTP_BAD_REQUEST = 400

  # HTTP 401 Unauthorized
  HTTP_UNAUTHORIZED = 401

  # The {::Logger} instance used throughout the code
  attr_reader :logger

  # The {ArgoBridge::Core} instance passed to handlers
  attr_reader :core

  # The token used to authenticate requests from `argocd-notifications`. Set by the `ARGO_BRIDGE_TOKEN` environment
  # variable.
  ARGO_BRIDGE_TOKEN = ENV.fetch('ARGO_BRIDGE_TOKEN', '')

  # Create a new instance of ArgoBridge, initializing the Logger, and the GitHub and Slack
  # helpers. It also loads the configuration from `config.yaml` and stores all these as
  # instance @variables with corresponding accessors.
  def initialize(logger: nil)
    @logger = logger || create_logger
    @core = ArgoBridge::Core.new(logger: @logger)
    unless ARGO_BRIDGE_TOKEN && !ARGO_BRIDGE_TOKEN.empty?
      @logger.fatal('$ARGO_BRIDGE_TOKEN is not set or empty! Cowardly refusing to proceed...')
      return
    end
    @logger.debug("$ARGO_BRIDGE_TOKEN: ...#{ARGO_BRIDGE_TOKEN[-4..]}")
    @logger.debug("$DEPLOYMENT_NOTIFICATIONS_CHANNEL_ID: #{DEPLOYMENT_NOTIFICATIONS_CHANNEL_ID}")
    @logger.debug("$P_ARGOCD_NOTIFICATIONS_CHANNEL_ID: #{P_ARGOCD_NOTIFICATIONS_CHANNEL_ID}")
  end

  # Setup logging
  def create_logger
    logger = Logger.new($stdout, level: logging_level_from_environment)
    json_logging = ENV.fetch('ARGO_BRIDGE_JSON_LOGGING', 'true')
    return logger unless json_logging == 'true'

    logger.formatter = proc do |severity, timestamp, _progname, message|
      "#{{ severity:, timestamp:, message: }.to_json}\n"
    end
    logger
  end

  # Retrieve the value of `$ARGO_BRIDGE_LOGGING_LEVEL` and convert that to a `Logger` level constant.
  #
  # Defaults to Logger::INFO. Set `$ARGO_BRIDGE_LOGGING_LEVEL` to 'debug' to enable debug logging.
  def logging_level_from_environment
    argo_bridge_logging_level = ENV.fetch('ARGO_BRIDGE_LOGGING_LEVEL', 'debug')
    argo_bridge_logging_level && argo_bridge_logging_level.downcase == 'debug' ? Logger::DEBUG : Logger::INFO
  end

  # The handler entrypoint. First, calls {#authorization_check} to check for the `Authorization` bearer token, then, if
  # that passes, calls {#handle_raw_body}.
  #
  # @param headers the HTTP request headers as a {::Hash}
  # @param body the HTTP POST request body
  def handle(headers, body)
    return HTTP_UNAUTHORIZED unless authorization_check(headers)

    if !body || body.empty?
      logger.warn('Request body is empty!')
      return HTTP_BAD_REQUEST
    end

    handle_raw_body(body)
  rescue StandardError => e
    logger.fatal(([e.message] + e.backtrace).join("\n"))
    HTTP_BAD_REQUEST
  end

  # Check for the presence of the `Authorization` request header, and check that the value is a `Bearer` token
  # equal to `$ARGO_BRIDGE_TOKEN`
  #
  # @param headers the HTTP request headers as a {::Hash}
  def authorization_check(headers)
    # Check for auth header
    authorization = headers.delete('authorization') # except this, too

    unless authorization
      logger.error('No authorization header provided!')
      return
    end

    headers.each { |k, v| logger.debug("#{k}: #{v}") }

    logger.debug("Authorization: #{authorization[0..10]}")

    return unless authorization.start_with?('Bearer ')

    bearer_token = authorization[7..]
    logger.error("Bearer token unrecognized! (#{bearer_token[0..4]})") unless bearer_token == ARGO_BRIDGE_TOKEN

    bearer_token == ARGO_BRIDGE_TOKEN
  end

  # Attempt to parse the request body as {::JSON}. If it fails, returns `HTTP 400 Bad Request`. Otherwise, proceeds to
  # call {#handle_json_body} with the JSON as as a {::Hash}
  #
  # @param body the HTTP request body as a raw string
  def handle_raw_body(body)
    handle_json_body(JSON.parse(body))
  rescue JSON::ParserError => e
    logger.fatal("body: #{body.inspect}")
    logger.fatal(([e.message] + e.backtrace).join("\n"))
    HTTP_BAD_REQUEST
  end

  # Now that we have a JSON object, determine if it's an Argo Rollouts or ArgoCD notification,
  # and call the appropriate handler.
  #
  # @param body the JSON request body as a {::Hash}
  def handle_json_body(body)
    logger.debug("body: #{body.to_json}") if ENV['ARGO_BRIDGE_LOG_BODY'] == 'true'

    # TODO: Implement this

    HTTP_NO_CONTENT
  end
end
