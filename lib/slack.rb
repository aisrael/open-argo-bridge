# frozen_string_literal: true

require 'logger'
require 'httparty'
require 'uri'

# Slack interface
class Slack # rubocop:disable Metrics/ClassLength
  include HTTParty

  # The Slack API token to use, from the `$SLACK_TOKEN` environment variable
  SLACK_TOKEN = ENV.fetch('SLACK_TOKEN', nil)
  # Ref: https://api.slack.com/apps/A01PE453YDP
  SLACK_APP_ID = 'A01PE453YDP'

  base_uri 'https://slack.com/api'
  headers 'Content-Type' => 'application/json; charset=utf-8',
          'Authorization' => "Bearer #{SLACK_TOKEN}"

  # The logger instance used throughout the code
  attr_reader :logger

  # The map of email addresses to Slack users
  attr_reader :known_users

  # Initialize an instance of this Slack helper class.
  #
  # @param logger A {::Logger} instance
  def initialize(logger:)
    @logger = logger || ::Logger.new($stdout, level: ::Logger::DEBUG)
    @logger.debug(%($SLACK_TOKEN: ...#{SLACK_TOKEN[-4..] if SLACK_TOKEN}))
    @known_users = {}
  end

  # Find a Slack user by email address.
  #
  # @param email the email address
  #
  # @return the Slack user's details, or `nil` if not found
  #
  # @see https://api.slack.com/methods/users.lookupByEmail
  def lookup_user_by_email(email) # rubocop:disable Metrics/AbcSize
    return @known_users[email] if @known_users.key?(email)

    url = '/users.lookupByEmail'
    resp = self.class.get(url, query: { email: })

    if resp.code == 200
      if (parsed_response = resp.parsed_response) && parsed_response['ok']
        user = parsed_response['user']
        @known_users[email] = user
        user
      end
    else
      logger.error("POST #{resp.request.last_uri} returned #{resp.code}!")
    end
  rescue StandardError => e
    logger.fatal(([e.message] + e.backtrace).join("\n"))
  ensure
    nil
  end

  # Sends a message to a channel
  #
  # @param channel_id the Slack channel to send the message to
  # @param args additional arguments to pass in the content of the message as Slack message blocks
  # @param thread_search_string If this string is present in a recent message, the message will be posted as a thread reply
  # @param thread_reply_broadcast Whether to thread the messages as a reply to the thread's parent message
  #
  # @return the result of the operation
  #
  # @see https://api.slack.com/methods/chat.postMessage
  # @see https://api.slack.com/block-kit/building
  def post_message(channel_id:, args:, thread_search_string: nil, thread_reply_broadcast: false) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/CyclomaticComplexity
    body = {
      channel: channel_id
    }.merge(args)

    # if thread_search_string is not nil and not empty, then try to find a thread in the channel using find_thread()
    if thread_search_string && !thread_search_string.empty?
      if (message = find_thread(channel_id:, search_string: thread_search_string, limit: 100))
        logger.debug("Found thread in channel #{channel_id} with search string #{thread_search_string}")
        body[:thread_ts] = message['thread_ts'] || message['ts']
        # puts message
      end

      body[:reply_broadcast] = true if thread_reply_broadcast
    end

    url = '/chat.postMessage'
    resp = self.class.post(url, body: body.to_json)

    if resp.code == 200
      if (parsed_response = resp.parsed_response)
        logger.debug("POST #{resp.request.last_uri} returned #{resp.code}")
        return parsed_response
      end
    else
      logger.error("POST #{resp.request.last_uri} returned #{resp.code}!")
    end
    nil
  end

  # Open a conversation (DM) with a Slack user
  #
  # @param user the Slack user id to open
  #
  # @return the result of the operation
  #
  # @see https://api.slack.com/methods/conversations.open
  def open_conversation(user:) # rubocop:disable Metrics/AbcSize
    return unless user && !user.empty?

    url = '/conversations.open'
    body = { users: [user], return_im: true }.to_json
    resp = self.class.post(url, body:)

    if resp.code == 200
      if (parsed_response = resp.parsed_response)
        logger.debug("POST #{resp.request.last_uri} returned #{resp.code}")
        return parsed_response
      end
    else
      logger.error("POST #{resp.request.last_uri} returned #{resp.code}!")
    end
    nil
  end

  # Argo Bridge in your DMs
  #
  # @param slack_user_id the Slack user id to send the message to
  # @param args additional arguments to pass in the content of the message as Slack message blocks
  # @param thread_search_string If this string is present in a recent message, the message will be posted as a thread reply
  # @param thread_reply_broadcast Whether to thread the messages as a reply to the thread's parent message
  def send_slack_direct_message_to_user(slack_user_id:, args:, thread_search_string:, thread_reply_broadcast: false)
    logger.debug("send_slack_direct_message_to_user(#{slack_user_id}, args:)")
    return unless (resp = open_conversation(user: slack_user_id))

    channel_id = resp['channel']['id']
    logger.debug("Opened conversation with #{slack_user_id} in channel #{channel_id}")
    post_message(channel_id:, args:, thread_search_string:, thread_reply_broadcast:)
  end

  # Fetches a conversation's history of messages and events
  #
  # @param channel_id Conversation ID to fetch history for
  #
  # @return the result of the operation
  #
  # @see https://api.slack.com/methods/conversations.history
  def conversations_history(channel_id:, limit: 10, cursor: '') # rubocop:disable Metrics/AbcSize
    return unless channel_id && !channel_id.empty?

    url = '/conversations.history'
    body = { channel: channel_id, limit:, cursor: }.to_json
    resp = self.class.post(url, body:)

    if resp.code == 200
      if (parsed_response = resp.parsed_response)
        logger.debug("POST #{resp.request.last_uri} returned #{resp.code}")
        # logger.debug("#{parsed_response}")
        return parsed_response
      end
    else
      logger.error("POST #{resp.request.last_uri} returned #{resp.code}!")
    end
    nil
  end

  # Find a thread in a channel
  #
  # @param channel_id Conversation ID to fetch history for
  # @param search_string String that must be present in the message
  # @param limit Number of messages to fetch
  #
  # @return the message if found, nil otherwise
  def find_thread(channel_id:, search_string:, limit: 10) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    return unless channel_id && !channel_id.empty?
    return unless search_string && !search_string.empty?

    logger.debug("find_thread(#{channel_id}, #{search_string}, limit: #{limit})")

    resp = conversations_history(channel_id:, limit:)
    if resp['ok']
      if resp['messages'].length.positive?
        logger.debug("conversations_history(channel_id: #{channel_id}, limit: #{limit}) returned (#{resp['messages'].length} messages)")

        resp['messages'].each do |message|
          next unless message['app_id'] == SLACK_APP_ID # only messages from Argo Bridge
          next unless message['text'].include?(search_string) # only messages that contain the search string

          if message['thread_ts'] && message['thread_ts'] == message['ts']
            logger.debug("Found message: (thead_ts: #{message['thread_ts']})")
            # logger.debug("#{message}")
            return message
          end

          logger.debug("Found message w/o matching thread_ts: (ts: #{message['ts']})")
          # logger.debug("#{message}")
          return message
        end
      else
        logger.info("conversations_history(channel_id: #{channel_id}, limit: #{limit}) returned no messages")
      end
    else
      logger.error("conversations_history(channel_id: #{channel_id}, limit: #{limit}) returned #{resp}")
    end
    nil
  end
end
