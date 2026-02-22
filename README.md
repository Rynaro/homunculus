# Homunculus

Personal AI agent running on your home server. Privacy-first, security-conscious, locally-hosted.

## Quick Start

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

## Architecture

```
┌──────────────┐     ┌─────────────────┐     ┌──────────────┐
│   Gateway    │────▶│   Agent Loop    │────▶│   Tools      │
│  (Roda/Puma) │     │  (Core Logic)   │     │  (Registry)  │
│ 127.0.0.1    │     │                 │     │              │
└──────────────┘     └────────┬────────┘     └──────┬───────┘
                              │                      │
                     ┌────────▼────────┐     ┌──────▼───────┐
                     │   LLM Models   │     │   Sandbox    │
                     │ Local / Claude  │     │  (Docker)    │
                     └─────────────────┘     └──────────────┘
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

## License

MIT
