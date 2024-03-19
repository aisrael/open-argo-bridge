# frozen_string_literal: true

require 'csv'
require 'yaml'

class ArgoBridge
  # The contents of `config.yaml` as a {::Hash}
  CONFIG = YAML.load_file('config.yaml')

  USERS = CSV.parse(File.open('users.csv'), headers: true).map(&:to_h)

  # Factored this out into its own class so that shared information and helpers can be
  # easily accessed by the handlers
  class Core
    # The {::Logger} instance used throughout the code
    attr_reader :logger

    # {GitHub} helper
    attr_reader :github

    # {Slack} helper
    attr_reader :slack

    # Create a new Config Helper
    def initialize(logger:, github: nil, slack: nil)
      @logger = logger
      @logger.datetime_format = '%s'
      @github = github || GitHub.new(logger:)
      @slack = slack || Slack.new(logger:)
    end

    # Attempt to lookup the 'deployment' by first checking `config.yaml`, otherwise, attempts a GitHub lookup.
    #
    # If deployment is in `config.yaml`, then calls {GitHub#get_repository} to check if the deployment exists as a repo
    # under the $GITHUB_ORG_NAME organization.
    #
    # @param deployment_name the deployment name
    # @return the deployment info as configured in `config.yaml`, or, as a {::Hash} containing
    #         `{'github' => '#{GITHUB_ORG_NAME}/repository_name'}`, or `nil` if the deployment is not recognized and GitHub lookup
    #         failed to find a corresponding GitHub repository
    def lookup_deployment(deployment_name)
      deployment = CONFIG['deployments'][deployment_name]
      if deployment
        return deployment if deployment.key?('github')

        logger.debug(%(Deployment "#{deployment_name}" has no 'github' config, will attempt to lookup GitHub) +
                     %(repository "#{GITHUB_ORG_NAME}/#{deployment_name}"!))
      else
        logger.debug(%(Deployment "#{deployment_name}" not in config.yaml, will attempt to lookup GitHub repository "#{GITHUB_ORG_NAME}/#{deployment_name}"!))
        deployment = {}
      end

      repository = github.get_repository("#{GITHUB_ORG_NAME}/#{deployment_name}")

      return unless repository

      deployment.merge({ 'github' => { 'repository' => repository.full_name } })
    end

    # safely extract 'user.login' from the pull_requests, ignoring nils and duplicates
    def extract_github_logins_from_pull_requests(pull_requests)
      return [] if pull_requests.empty?

      github_logins = pull_requests.each_with_object({}) do |pr, hash|
        github_login = pr.dig('user', 'login')
        logger.debug("- #{pr['id']}: #{pr['url']} by #{github_login}")

        next if hash.key?(github_login)

        if (slack_id = find_slack_id_for(github_login))
          hash.store(github_login, slack_id)
        end
      end

      logger.debug("Found #{github_logins.size} known GitHub logins: #{github_logins.keys.join(', ')}")
      github_logins
    end

    # Attempt to lookup the Slack id for the given GitHub username.
    #
    # First attempts to call {GitHub#get_user} and retrieve the user's email. If the user's email is available, then
    # attempt to call {Slack#lookup_user_by_email} to find the Slack id.
    #
    # @param github_login the GitHub username
    # @return the Slack id, or `nil` if unsuccesful
    def find_slack_id_for(github_login)
      configured_user = USERS.find { |user| github_login == user['github_login'] }

      return configured_user['slack_id'] if configured_user

      github_user = github.get_user(github_login)
      logger.debug("github_user: #{github_user.inspect}")

      return nil unless github_user

      github_user_email = github_user['email']

      return nil unless github_user_email

      slack_user = slack.lookup_user_by_email(github_user['email'])

      return nil unless slack_user

      slack_user['id']
    end
  end
end
