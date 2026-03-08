# Homunculus

Personal AI agent running on your home server. Privacy-first, security-conscious, locally-hosted.

## Quick Start

**Production (recommended):** use `bin/assistant` for a single entrypoint that handles setup, start, recovery, and observability.

```bash
# First-run setup and start
chmod +x bin/assistant
bin/assistant setup
bin/assistant up --with-ollama

# Or without Ollama in Docker (use host Ollama)
bin/assistant up
```

**Alternative (manual):**

```bash
# First-run setup
chmod +x scripts/setup.sh
./scripts/setup.sh

# Start with Docker
docker compose up -d

# Or run locally
bundle exec ruby bin/homunculus serve

# Interactive CLI
bundle exec ruby bin/homunculus cli
```

**Assistant commands:** `bin/assistant help` — lifecycle (setup, up, down, restart), recovery (doctor, obliterate), observability (status, logs, validate, shell), and interactive **cli** / **tui** (e.g. `bin/assistant cli`, `bin/assistant tui`).

### Model management

Use **`bin/ollama`** to see which Ollama models Homunculus expects (from `config/models.toml` and the embedding model in `config/default.toml`), which are installed, and to pull or remove them. Works with host Ollama or Ollama in Docker (`bin/assistant up --with-ollama`).

**Without host Ruby:** Copy `config/ollama.env.example` to `config/ollama.env` and set `BIN_OLLAMA_USE_DOCKER=1`. All Ollama and Ruby commands then run via Docker (requires `bin/assistant up --with-ollama`).

```bash
bin/ollama              # or bin/ollama list — fleet table (Installed/Missing)
bin/ollama status       # Ollama reachability and fleet summary
bin/ollama pull <tier>  # e.g. whisper, workhorse, coder, thinker, embedding
bin/ollama pull --all   # pull all missing fleet models
bin/ollama remove <tier>
bin/ollama help
```

## Architecture

```
┌──────────────┐      ┌─────────────────┐      ┌──────────────┐
│   Gateway    │────▶│   Agent Loop    │────▶│   Tools      │
│  (Roda/Puma) │      │  (Core Logic)   │      │  (Registry)  │
│ 127.0.0.1    │      │                 │      │              │
└──────────────┘      └────────┬────────┘      └──────┬───────┘
                               │                      │
                      ┌────────▼────────┐      ┌──────▼───────┐
                      │   LLM Models    │      │   Sandbox    │
                      │ Local / Claude  │      │  (Docker)    │
                      └─────────────────┘      └──────────────┘
```

### Components

| Component | Purpose |
|-----------|---------|
| **Gateway** | HTTP API bound to 127.0.0.1 only. Roda + Puma. |
| **Agent Loop** | Core reasoning loop with tool dispatch. Max 25 turns. |
| **Models** | Local (Ollama) for routine, Anthropic for escalation. |
| **Tools** | Pluggable tool registry. Sandbox-first execution. |
| **Memory** | SQLite + embeddings for persistent context (M2). |
| **Audit** | Append-only JSONL log of all agent actions. |
| **Sandbox** | Docker container with no network, read-only FS. |

## Configuration

Configuration lives in `config/default.toml`. Environment variables override config values.

Key settings:
- `ANTHROPIC_API_KEY` — Required for escalation model
- `GATEWAY_AUTH_TOKEN_HASH` — bcrypt hash for API auth
- `LOG_LEVEL` — debug, info, warn, error, fatal

See `.env.example` for all options.

## Security

- Gateway binds to `127.0.0.1` only — enforced in code with runtime assertion
- Tool execution in isolated Docker containers (no network, no capabilities)
- Append-only audit log with hashed inputs/outputs
- Credentials never stored in config files
- Confirmation required for destructive operations

## Development

```bash
# Install dependencies
bundle install

# Run specs
bundle exec rspec

# Validate config
bundle exec ruby bin/homunculus validate

# Interactive console
bundle exec ruby bin/console
```

## Project Structure

```
homunculus/
├── config/          # Configuration (TOML + bootstrap)
├── lib/homunculus/  # Core application code
│   ├── agent/       # Agent loop, prompts, model abstraction
│   ├── gateway/     # HTTP API server
│   ├── tools/       # Tool registry and base class
│   ├── memory/      # Persistent memory (stub for M2)
│   ├── security/    # Audit logging, sandbox manager
│   ├── interfaces/  # CLI and future interfaces
│   └── utils/       # Structured logging
├── workspace/       # Agent persona, instructions, memory
├── spec/            # RSpec test suite
├── bin/             # Entry points
└── scripts/         # Setup and maintenance scripts
```

## Docker troubleshooting

If you see an error like `failed to set up container networking: network ... not found`, Docker has a stale reference to a removed network. Use the assistant entrypoint (it runs pre-flight cleanup automatically), or recover manually:

```bash
# Recommended: use the assistant (runs pre-flight before every up)
bin/assistant up --with-ollama

# Or nuclear reset then start
bin/assistant obliterate --confirm
bin/assistant up --with-ollama
```

Diagnostics: `bin/assistant doctor`. Manual cleanup: `docker compose down`, `docker rm -f homunculus-ollama 2>/dev/null`, `docker network prune -f`, then `bin/assistant up` again.

## License

MIT
