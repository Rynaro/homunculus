FROM ruby:4.0-slim

ENV RUBY_YJIT_ENABLE=1
ENV LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libsqlite3-dev libffi-dev gosu \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 homunculus
WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set --local without 'development test' && \
    bundle install --jobs 4

COPY --chown=homunculus:homunculus . .

ENTRYPOINT ["/app/scripts/docker-entrypoint.sh"]
CMD ["bundle", "exec", "ruby", "bin/homunculus"]
