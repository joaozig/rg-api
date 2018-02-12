FROM ruby:2.3.1

RUN apt-get update -qq && apt-get install -y build-essential

RUN apt-get install -y libpq-dev

RUN gem install bundler

RUN mkdir /app
WORKDIR /app

ADD Gemfile /app/Gemfile
ADD Gemfile.lock /app/Gemfile.lock
RUN bundle install

ADD . /app

RUN mkdir -p log && \
    mkdir -p tmp/cache \
    mkdir -p tmp/pids \
    mkdir -p tmp/sessions \
    mkdir -p tmp/sockets
