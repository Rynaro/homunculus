# Quick Setup

Get Homunculus running in under 5 minutes.

## Prerequisites

| Dependency | Version | Notes |
|------------|---------|-------|
| Ruby | >= 3.4 (4.0 recommended) | Docker image uses Ruby 4.0; local dev works with 3.4+ |
| Docker | Latest stable | Required for sandbox and containerized deployment |
| Docker Compose | v2+ | Bundled with Docker Desktop |
| Ollama | Latest | Local LLM inference; install from [ollama.com](https://ollama.com) |

## Option A: Automated Setup (recommended)

The setup script handles everything: directory creation, `.env` generation, dependency installation, model pulling, and Docker builds.

```bash
git clone <your-repo-url> homunculus
cd homunculus

chmod +x scripts/setup.sh
./scripts/setup.sh
```

The script will:

1. Verify Ruby 4.0+, Docker, and Docker Compose are installed
2. Create `data/` and `workspace/memory/` directories
3. Generate `.env` from `.env.example` with a random auth token (bcrypt-hashed)
4. Run `bundle install`
5. Pull the default Ollama model (`qwen2.5:14b`) if Ollama is available
6. Build Docker images
7. Run the test suite

**Important:** The script prints your gateway auth token exactly once. Save it securely -- it will not be shown again.

### Start with Docker

```bash
docker compose up -d
```

### Start locally (no Docker)

```bash
bundle exec ruby bin/homunculus serve
```

## Option B: Manual Setup

If you prefer to set things up step by step:

```bash
# 1. Install Ruby dependencies
bundle install

# 2. Create data directories
mkdir -p data workspace/memory

# 3. Create .env from the example
cp .env.example .env

# 4. Generate an auth token and hash it
ruby -e "
  require 'securerandom'
  require 'bcrypt'
  token = SecureRandom.hex(32)
  hash = BCrypt::Password.create(token)
  puts \"Token: #{token}\"
  puts \"Hash:  #{hash}\"
"
# Paste the hash into .env as GATEWAY_AUTH_TOKEN_HASH

# 5. (Optional) Set your Anthropic API key for escalation
# Edit .env and set ANTHROPIC_API_KEY=sk-ant-...

# 6. Pull the default Ollama model
ollama pull qwen2.5:14b

# 7. Start the server
bundle exec ruby bin/homunculus serve
```

## Verify the Installation

Once the server is running, check the status endpoint:

```bash
curl http://127.0.0.1:18789/api/v1/status
```

Expected response:

```json
{
  "status": "running",
  "version": "0.1.0",
  "uptime_seconds": 5
}
```

## Interactive CLI

For quick testing without the HTTP gateway:

```bash
bundle exec ruby bin/homunculus cli
```

If `config/models.toml` exists, the CLI uses the models router with **streaming**: tokens appear as they are generated and the request timeout applies per stream (avoids single long timeouts). Otherwise the CLI uses the legacy provider and `timeout_seconds` from `[models.local]`.

You can override the model provider:

```bash
# Use Anthropic directly
bundle exec ruby bin/homunculus cli --provider escalation

# Use a specific model
bundle exec ruby bin/homunculus cli --provider local --model llama3:8b
```

CLI commands once inside the session:

| Command | Description |
|---------|-------------|
| `help` | Show available commands and tools |
| `status` | Session info and token usage |
| `confirm` | Approve a pending tool action |
| `deny` | Reject a pending tool action |
| `quit` | Exit the CLI |

## Validate Configuration

Check that your `config/default.toml` and environment variables are correct:

```bash
bundle exec ruby bin/homunculus validate
```

This prints the resolved gateway address, model names, and workspace path.

## Minimal Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `GATEWAY_AUTH_TOKEN_HASH` | Yes | bcrypt hash of your API auth token |
| `OLLAMA_BASE_URL` | For Docker + ollama profile | Set to `http://ollama:11434` when using the ollama Docker Compose profile. **Required** to avoid connection timeouts. |
| `OLLAMA_TIMEOUT_SECONDS` | No | Override Ollama request timeout (seconds). Use 180–300+ for 14B or large prompts if you see timeouts. |
| `ANTHROPIC_API_KEY` | No | Enables Claude as the escalation model |
| `ESCALATION_ENABLED` | No | Set to `false` for local-only mode (no Claude). Default: `true` |
| `LOG_LEVEL` | No | `debug`, `info` (default), `warn`, `error`, `fatal` |

See [configuration.md](configuration.md) for the full reference.

## Ollama in Docker (optional)

By default, Homunculus expects Ollama running on the host (reachable at `http://host.docker.internal:11434` from inside Docker, or `http://localhost:11434` when running natively).

To run Ollama as a Docker container alongside Homunculus:

```bash
# 1. Add OLLAMA_BASE_URL to .env (required — prevents connection timeouts)
echo 'OLLAMA_BASE_URL=http://ollama:11434' >> .env

# 2. Start Homunculus with the ollama profile
docker compose --profile ollama up -d

# 3. Pull a model inside the Ollama container
docker exec homunculus-ollama ollama pull qwen2.5:14b

# 4. Restart the agent so it picks up OLLAMA_BASE_URL (if already running)
docker compose restart homunculus-agent

# 5. Validate that Ollama is reachable
docker compose exec homunculus-agent bundle exec ruby bin/homunculus validate
```

The `validate` command will print `Ollama: reachable` when the connection is working. **If you omit `OLLAMA_BASE_URL`, Homunculus will timeout** trying to reach Ollama (the default `host.docker.internal` does not work when Ollama runs in a container). Without the `ollama` profile, Homunculus continues to work with Ollama on the host — no changes needed.

### GPU acceleration (Linux / NVIDIA only)

The Docker Compose file reserves all available NVIDIA GPUs for the Ollama container by default. To use GPU acceleration:

1. Install the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) on the host.
2. Verify the driver is visible to Docker:

```bash
docker run --rm --gpus all nvidia/cuda:12.3.1-base-ubuntu22.04 nvidia-smi
```

3. Start Ollama normally — the `deploy.resources.reservations` block in `docker-compose.yml` handles the rest:

```bash
docker compose --profile ollama up -d
```

On **macOS**, Docker Desktop does not support NVIDIA GPU passthrough. The `deploy` block is safely ignored and Ollama will run on CPU.

## Telegram Bot (optional)

To enable the Telegram interface:

1. Create a bot via [@BotFather](https://t.me/BotFather) on Telegram
2. Set `TELEGRAM_BOT_TOKEN` in `.env`
3. Add your Telegram user ID to `allowed_user_ids` in `config/default.toml`
4. Start the Telegram interface:

```bash
bundle exec ruby bin/homunculus telegram
```

See [interfaces.md](interfaces.md) for details.

## Next Steps

- [Configuration Reference](configuration.md) -- all settings explained
- [Architecture](architecture.md) -- how the components fit together
- [Workspace Customization](workspace.md) -- create agents and skills
- [Security Model](security.md) -- sandbox, audit, and access control
- [Interfaces](interfaces.md) -- Gateway API, CLI, and Telegram
- [Development Guide](development.md) -- testing, extending, and contributing
