FROM ruby:3.3-alpine

RUN apk add --no-cache build-base libxml2-dev libxslt-dev ca-certificates

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install --without development test

COPY . .

EXPOSE 4567

CMD ["bundle", "exec", "rackup", "config.ru", "-p", "4567", "-o", "0.0.0.0"]