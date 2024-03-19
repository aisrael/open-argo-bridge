# frozen_string_literal: true

require 'logger'
require 'httparty'
require 'octokit'
require 'uri'

# GitHub interface
class GitHub # rubocop:disable Metrics/ClassLength
  include HTTParty
  base_uri 'https://api.github.com'
  headers 'Content-Type' => 'application/json',
          'Authorization' => "Bearer #{ENV.fetch('GITHUB_TOKEN', nil)}"

  # The logger instance used throughout the code
  attr_reader :logger

  # The map of GitHub logins to GitHub users
  attr_reader :known_users

  # Initialize an instance of this GitHub helper class.
  #
  # @param logger A {::Logger} instance
  def initialize(logger: nil)
    @logger = logger || ::Logger.new($stdout, level: ::Logger::DEBUG)
    @github_token = ENV.fetch('GITHUB_TOKEN', nil)
    @octokit = Octokit::Client.new(access_token: @github_token)
    if @github_token
      @logger.debug(%($GITHUB_TOKEN: ...#{@github_token[-4..]}))
    else
      @logger.warn(%(ENV['GITHUB_TOKEN'] is nil!))
    end
    @known_users = {}
  end

  # We hard-code this login to avoid making an API call to fetch the user details.
  DEPENDABOT_GITHUB_LOGIN = 'dependabot[bot]'

  # Fetch a GitHub user's details.
  #
  # @param github_login the GitHub user login
  #
  # @return the GitHub user's details, or `nil` if not found
  #
  # @see https://docs.github.com/en/rest/users/users?apiVersion=2022-11-28#get-a-user
  def get_user(github_login) # rubocop:disable Metrics/AbcSize
    return nil if github_login == DEPENDABOT_GITHUB_LOGIN
    return @known_users[github_login] if @known_users.key?(github_login)

    url = "/users/#{github_login}"

    resp = self.class.get(url)
    if resp.code != 200
      logger.error("GET #{resp.request.last_uri} returned #{resp.code}!")
      return nil
    end

    user = resp.parsed_response
    @known_users[github_login] = user

    user
  rescue StandardError => e
    logger.fatal(([e.message] + e.backtrace).join("\n"))
    nil
  end

  # Fetch a GitHub repository's details.
  #
  # @param full_repo_name the full GitHub repository name, `{owner}/{repo}`
  #
  # @return the GitHub repository details, or `nil` if not found
  #
  # @see https://docs.github.com/en/rest/repos/repos#get-a-repository
  def get_repository(full_repo_name)
    @octokit.repository(full_repo_name)
  rescue Octokit::NotFound => e
    logger.info(e.message)
    nil
  rescue StandardError => e
    logger.fatal(([e.message] + e.backtrace).join("\n"))
    nil
  end

  # Fetch a commit's details.
  # @param full_repo_name the full GitHub repository name, `{owner}/{repo}`
  # @param commit_sha the commit SHA
  #
  # @return the commit details, or `nil` if not found
  #
  # @see Octokit::Client#commit
  def get_commit(full_repo_name, commit_sha)
    @octokit.commit(full_repo_name, commit_sha)
  rescue Octokit::NotFound => e
    logger.info(e.message)
    nil
  rescue StandardError => e
    logger.fatal(([e.message] + e.backtrace).join("\n"))
    nil
  end

  # Get the latest deployment for a given repository, environment, and commit SHA.
  #
  # @param repo the full GitHub repository name, `{owner}/{repo}`
  # @param environment the deployment environment configured in GitHub
  # @param sha the Git commit SHA that was deployed
  #
  # @return the deployment details, or `nil`
  #
  # @see https://docs.github.com/en/rest/deployments/deployments?apiVersion=2022-11-28#list-deployments
  def get_latest_deployment(repo, environment, sha) # rubocop:disable Metrics/AbcSize
    logger.debug("get_latest_deployment(#{repo}, #{environment}, #{sha})...")
    url = "/repos/#{repo}/deployments"

    resp = self.class.get(url,
                          query: {
                            environment:,
                            sha:,
                            per_page: 1
                          })

    logger.debug("response: #{resp.inspect}")
    logger.error("GET #{resp.request.last_uri} returned #{resp.code}!") if resp.code != 200

    if (parsed_response = resp.parsed_response) && parsed_response.is_a?(Array) && !parsed_response.empty?
      parsed_response.first
    end
  rescue StandardError => e
    logger.fatal(([e.message] + e.backtrace).join("\n"))
  ensure
    nil
  end

  # Set the deployment status for the given repository and deployment id to the given state.
  #
  # @param repo the full GitHub repository name, `{owner}/{repo}`
  # @param deployment_id the deployment id (such as the one returned from {#get_latest_deployment})
  # @param state the deployment state, can be one of `error`, `failure`, `inactive`, `in_progress`, `queued`, `pending`, or `success`
  #
  # @return the deployment status
  #
  # @see https://docs.github.com/en/rest/deployments/statuses?apiVersion=2022-11-28#create-a-deployment-status
  def set_deployment_status(repo, deployment_id, state) # rubocop:disable Metrics/AbcSize
    logger.debug("set_deployment_status(#{repo}, #{deployment_id}, #{state})")
    url = "/repos/#{repo}/deployments/#{deployment_id}/statuses"

    resp = self.class.post(url, body: { state: }.to_json)

    logger.debug("response: #{resp}")
    return resp.parsed_response if resp.code == 201

    logger.error("POST #{resp.request.last_uri} returned #{resp.code}!")
  rescue StandardError => e
    logger.fatal(([e.message] + e.backtrace).join("\n"))
  ensure
    nil
  end

  # Invoke a workflow using [workflow dispatch](https://docs.github.com/en/developers/webhooks-and-events/webhooks/webhook-events-and-payloads#workflow_dispatch)
  #
  # @param workflow_repo the full GitHub repository name, `{owner}/{repo}`
  # @param workflow_ref the git reference for the workflow. The reference can be a branch or tag name.
  # @param workflow_name the workflow id or name
  # @param inputs input keys and values configured in the workflow file
  #
  # @see https://docs.github.com/en/rest/actions/workflows?apiVersion=2022-11-28#create-a-workflow-dispatch-event
  def invoke_workflow_dispatch(workflow_repo, workflow_ref, workflow_name, **inputs)
    logger.info(%(Invoking workflow dispatch #{workflow_name} in #{workflow_repo}:#{workflow_ref} with inputs #{inputs.inspect}))

    url = "/repos/#{workflow_repo}/actions/workflows/#{workflow_name}/dispatches"

    body = {
      ref: workflow_ref,
      inputs:
    }.to_json

    response = self.class.post(url, body:)

    logger.debug("res: #{response.inspect}")
  rescue StandardError => e
    logger.fatal(([e.message] + e.backtrace).join("\n"))
  end

  # Lists the merged pull request that introduced the commit to the repository.
  #
  # @param repo the full GitHub repository name, `{owner}/{repo}`
  # @param commit_sha the SHA of the commit
  #
  # @return an array of pull request information, or `nil` on any error
  #
  # @see https://docs.github.com/en/rest/commits/commits?apiVersion=2022-11-28#list-pull-requests-associated-with-a-commit
  def list_pull_requests_for_commit(repo, commit_sha) # rubocop:disable Metrics/AbcSize
    logger.debug(%(list_pull_requests_for_commit(#{repo}, #{commit_sha})))

    url = "/repos/#{repo}/commits/#{commit_sha}/pulls"

    resp = self.class.get(url)

    logger.error("GET #{resp.request.last_uri} returned #{resp.code}!") unless resp.code == 200

    resp.parsed_response
  rescue StandardError => e
    logger.fatal(([e.message] + e.backtrace).join("\n"))
  ensure
    nil
  end

  # Try to find the workflow run for a given repo and commit
  def determine_workflow_run_for_commit(repo:, workflow_name:, commit_sha:) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
    raise ArgumentError, 'repo is required!' unless repo && !repo.empty?
    raise ArgumentError, 'workflow_name is required!' unless workflow_name && !workflow_name.empty?
    raise ArgumentError, 'commit_sha is required!' unless commit_sha && !commit_sha.empty?

    workflow_runs = @octokit.workflow_runs(repo, workflow_name, event: 'push', head_sha: commit_sha).workflow_runs
    logger.debug("Found #{workflow_runs.length} workflow runs of #{repo}/#{workflow_name} for #{commit_sha[0..7]}.")
    workflow_runs.find do |wr|
      wr.head_sha == commit_sha
    end
  end
end
