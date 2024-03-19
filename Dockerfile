ARG RUBY_VERSION=3.2.2

FROM ruby:${RUBY_VERSION}-slim

EXPOSE 80

RUN mkdir -p /usr/src/app/tmp
WORKDIR /usr/src/app

RUN apt update && \
    apt install -y build-essential openssl libssl-dev jq

COPY Gemfile* .

RUN bundle config set --local without 'development test'
RUN bundle install

COPY . .

ENTRYPOINT ["/usr/local/bin/bundle"]
CMD [ "exec", "ruby", "app.rb", "-p", "80", "-o", "0.0.0.0" ]
