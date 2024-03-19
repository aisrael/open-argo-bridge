# frozen_string_literal: true

source 'https://rubygems.org'

git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }

gem 'httparty', '~> 0.21.0' # HTTP requests made easy
gem 'octokit', '~> 7.2.0' # Ruby client for GitHub API
gem 'sinatra', '~> 3.0.6' # DSL for quickly creating web applications in Ruby with minimal effort
gem 'thin', '~> 1.8' # A thin and fast web server for Sinatra

group :development do
  gem 'debug', '~> 1.9.1', require: false
  gem 'rake', '~> 13.0.6'
  gem 'rerun', '~> 0.14.0'
  gem 'vcr', '~> 6.2.0'
  gem 'webmock', '~> 3.18.1'
end

group :test do
  gem 'minitest', '~> 5.16.3'
  gem 'rubocop', '~> 1.56.0', require: false
  gem 'rubocop-minitest', '~> 0.31.0', require: false
  gem 'rubocop-rake', '~> 0.6.0', require: false
  gem 'spy', '~> 1.0.5'
  gem 'yard', '~> 0.9.28'
end
