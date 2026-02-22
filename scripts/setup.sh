#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

echo "============================================"
echo "  Homunculus — First-Run Setup"
echo "============================================"
echo ""

# ----- Check prerequisites -----

info "Checking prerequisites..."

# Ruby 4.0+
if command -v ruby &> /dev/null; then
  RUBY_VER=$(ruby -e 'puts RUBY_VERSION')
  RUBY_MAJOR=$(echo "$RUBY_VER" | cut -d. -f1)
  if [ "$RUBY_MAJOR" -lt 4 ]; then
    error "Ruby 4.0+ required, found $RUBY_VER"
  fi
  info "Ruby $RUBY_VER ✓"
else
  error "Ruby not found. Install Ruby 4.0+ first."
fi

# Docker
if command -v docker &> /dev/null; then
  DOCKER_VER=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
  info "Docker $DOCKER_VER ✓"
else
  error "Docker not found. Install Docker first."
fi

# Docker Compose
if docker compose version &> /dev/null; then
  COMPOSE_VER=$(docker compose version --short 2>/dev/null || echo "unknown")
  info "Docker Compose $COMPOSE_VER ✓"
elif command -v docker-compose &> /dev/null; then
  COMPOSE_VER=$(docker-compose --version | grep -oP '\d+\.\d+\.\d+' | head -1)
  info "Docker Compose $COMPOSE_VER ✓"
else
  error "Docker Compose not found. Install Docker Compose first."
fi

# ----- Create directories -----

info "Creating directories..."
mkdir -p data workspace/memory

# ----- Generate .env if not exists -----

if [ ! -f .env ]; then
  info "Generating .env from .env.example..."
  cp .env.example .env

  # Generate random auth token and hash it with bcrypt
  AUTH_TOKEN=$(ruby -e "require 'securerandom'; puts SecureRandom.hex(32)")
  AUTH_HASH=$(ruby -e "require 'bcrypt'; puts BCrypt::Password.create('$AUTH_TOKEN')")

  # Write to .env
  sed -i.bak "s|^GATEWAY_AUTH_TOKEN_HASH=.*|GATEWAY_AUTH_TOKEN_HASH=${AUTH_HASH}|" .env
  rm -f .env.bak

  info "Auth token generated. Save this token securely:"
  echo ""
  echo -e "  ${YELLOW}${AUTH_TOKEN}${NC}"
  echo ""
  warn "This token will NOT be shown again."
else
  info ".env already exists, skipping generation."
fi

# ----- Install Ruby dependencies -----

info "Installing Ruby dependencies..."
bundle install

# ----- Pull Ollama model (if Ollama is available) -----

if command -v ollama &> /dev/null; then
  MODEL="qwen2.5:14b"
  if ollama list 2>/dev/null | grep -q "$MODEL"; then
    info "Ollama model $MODEL already available ✓"
  else
    info "Pulling Ollama model $MODEL (this may take a while)..."
    ollama pull "$MODEL" || warn "Failed to pull model. You can pull it later with: ollama pull $MODEL"
  fi
else
  warn "Ollama not found locally. Make sure it's running on your server."
fi

# ----- Build Docker images -----

info "Building Docker images..."
docker compose build || warn "Docker build failed. You can build later with: docker compose build"

# ----- Run specs -----

info "Running specs..."
if bundle exec rspec --format documentation; then
  info "All specs passed ✓"
else
  warn "Some specs failed. Check output above."
fi

# ----- Done -----

echo ""
echo "============================================"
echo -e "  ${GREEN}Homunculus is ready!${NC}"
echo "============================================"
echo ""
echo "  Start the agent:"
echo "    docker compose up -d"
echo ""
echo "  Or run locally:"
echo "    bundle exec ruby bin/homunculus serve"
echo ""
echo "  Interactive CLI:"
echo "    bundle exec ruby bin/homunculus cli"
echo ""
echo "  Gateway endpoint:"
echo "    http://127.0.0.1:18789/api/v1/status"
echo ""
echo "  Console:"
echo "    bundle exec ruby bin/console"
echo ""
