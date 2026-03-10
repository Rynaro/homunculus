FROM ruby:4.0-slim

ENV RUBY_YJIT_ENABLE=1
ENV LANG=C.UTF-8

# Docker CLI for sandbox: spawn sibling containers via host socket
# ruby:4.0-slim is Debian-based; use bookworm (Docker supports trixie via bookworm repo fallback)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl build-essential libsqlite3-dev libffi-dev gosu \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 homunculus
WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set --local without 'development test' && \
    bundle install --jobs 4

COPY --chown=homunculus:homunculus . .

ENTRYPOINT ["/app/scripts/docker-entrypoint.sh"]
CMD ["bundle", "exec", "ruby", "bin/homunculus"]
