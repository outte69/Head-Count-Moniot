FROM ruby:3.2-slim

WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential libsqlite3-dev pkg-config \
  && rm -rf /var/lib/apt/lists/*

COPY Gemfile ./

RUN bundle install

COPY . .

RUN chmod +x /app/start.sh

ENV APP_ENV=production

EXPOSE 8080

CMD ["/app/start.sh"]
