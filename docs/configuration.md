# Configuration Reference

Homunculus is configured through a TOML file at `config/default.toml`. Environment variables override config values where noted. Secrets (API keys, tokens) must always be set via environment variables -- never in the config file.

## Config Loading

The configuration is loaded by `Homunculus::Config.load` (defined in `lib/homunculus/config.rb`). The load process:

1. Parse `config/default.toml`
2. Override specific values from environment variables
3. Validate constraints (e.g., gateway must bind to `127.0.0.1`)
4. Build typed config structs using `dry-struct`

## Environment Variables

These take precedence over values in `config/default.toml`:

| Variable | Maps To | Description |
|----------|---------|-------------|
| `GATEWAY_AUTH_TOKEN_HASH` | `gateway.auth_token_hash` | bcrypt hash of the API auth token |
| `ANTHROPIC_API_KEY` | `models.escalation.api_key` | Anthropic API key for Claude |
| `ESCALATION_ENABLED` | `models.escalation.enabled` | Set to `false` to disable remote escalation (local-only mode). Default: `true` |
| `TELEGRAM_BOT_TOKEN` | `interfaces.telegram.bot_token` | Telegram bot token from @BotFather |
| `MQTT_USERNAME` | `tools.mqtt.username` | MQTT broker username |
| `MQTT_PASSWORD` | `tools.mqtt.password` | MQTT broker password |
| `LOG_LEVEL` | Logging level | `debug`, `info`, `warn`, `error`, `fatal` |
| `OLLAMA_BASE_URL` | `models.local.base_url` | Override Ollama URL for host or dockerized Ollama. Set to `http://ollama:11434` when using the optional `ollama` Docker Compose profile |
| `OLLAMA_TIMEOUT_SECONDS` | `models.local.timeout_seconds` | Override Ollama request timeout in seconds (e.g. 300 for slow instances or large prompts). Default from config |
| `RUBY_YJIT_ENABLE` | Ruby runtime | Set to `1` to enable YJIT (default in Docker) |

## Configuration Sections

### `[gateway]`

HTTP API server settings. The gateway uses Roda + Puma.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `host` | String | `"127.0.0.1"` | Bind address. **Must** be `127.0.0.1` -- enforced at runtime |
| `port` | Integer | `18789` | Listen port |
| `auth_token_hash` | String | `""` | bcrypt hash of the auth token. Set via `GATEWAY_AUTH_TOKEN_HASH` env var |

The `127.0.0.1` binding is a hard security constraint enforced by `GatewayConfig#validate!`. The server will refuse to start if any other address is configured.

### `[models.local]`

Local LLM provider (Ollama) for routine tasks.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `provider` | String | `"ollama"` | Provider name |
| `base_url` | String | `"http://host.docker.internal:11434"` | Ollama API URL. Use `http://localhost:11434` when running outside Docker |
| `default_model` | String | `"qwen2.5:14b"` | Model to use for inference |
| `context_window` | Integer | `32768` | Max context tokens (Ollama `num_ctx`). Lower values (e.g. 8192) speed up inference for short chats |
| `temperature` | Float | `0.7` | Sampling temperature |
| `timeout_seconds` | Integer | `300` | Request timeout in seconds. Increase (180–300+) for 14B models or large prompts. Override via `OLLAMA_TIMEOUT_SECONDS` env var |

**Larger prompts** (system + memory + conversation history) increase response time and may require a higher `timeout_seconds` on CPU or slow instances.

### `[models.escalation]`

Cloud LLM provider (Anthropic) for complex reasoning, code generation, and research synthesis.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `provider` | String | `"anthropic"` | Provider name |
| `enabled` | Boolean | `true` | Set to `false` to disable remote escalation entirely (local-only mode). When disabled, all tasks route to the local model and Claude is never called. Override via `ESCALATION_ENABLED` env var |
| `model` | String | `"claude-sonnet-4-20250514"` | Anthropic model identifier |
| `context_window` | Integer | `200000` | Max context tokens |
| `temperature` | Float | `0.3` | Lower temperature for precise reasoning |
| `daily_budget_usd` | Float | `2.0` | Maximum USD spend per day. The router falls back to local when exhausted |

The API key is **never** stored in config. Set `ANTHROPIC_API_KEY` in your environment.

**Local-only mode:** To run Homunculus without any remote model dependency, set `ESCALATION_ENABLED=false` in your environment (or `enabled = false` in the config). This is ideal for experimenting with local models, stress-testing Ollama, or using your own fine-tuned models. Homunculus will start and operate normally — all tasks will be handled by the local provider.

### `[agent]`

Core agent loop settings.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `max_turns` | Integer | `25` | Maximum reasoning turns per request |
| `max_execution_time_seconds` | Integer | `300` | Hard timeout for agent execution (5 minutes) |
| `workspace_path` | String | `"./workspace"` | Path to the workspace directory containing agents, skills, and memory |

The path is relative to the process current working directory. Run Homunculus from the project root (or set an absolute path) so the assistant receives full context from `SOUL.md`, `AGENTS.md`, and `USER.md`.

### `[tools]`

Tool execution and approval settings.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `approval_mode` | String | `"elevated"` | `off` = no confirmations, `elevated` = confirm dangerous tools, `always` = confirm all |
| `safe_commands` | Array | `["ls", "cat", "grep", ...]` | Shell commands that skip confirmation |
| `blocked_patterns` | Array | `["rm -rf /", "mkfs", ...]` | Command patterns that are always rejected |

### `[tools.sandbox]`

Docker sandbox for tool execution. Commands run in an isolated container.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | Boolean | `true` | Enable Docker sandbox. When `false`, commands run directly on the host |
| `image` | String | `"homunculus-sandbox:latest"` | Docker image for the sandbox container |
| `network` | String | `"none"` | Docker network mode. `none` = no network access |
| `memory_limit` | String | `"512m"` | Container memory limit |
| `cpu_limit` | String | `"1.0"` | Container CPU limit |
| `read_only_root` | Boolean | `true` | Mount root filesystem as read-only |
| `drop_capabilities` | Array | `["ALL"]` | Linux capabilities to drop |
| `no_new_privileges` | Boolean | `true` | Prevent privilege escalation |

### `[tools.mqtt]`

MQTT client configuration for home automation.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `broker_host` | String | `"localhost"` | MQTT broker hostname |
| `broker_port` | Integer | `1883` | MQTT broker port |
| `username` | String | `""` | Override via `MQTT_USERNAME` env var |
| `password` | String | `""` | Override via `MQTT_PASSWORD` env var |
| `client_id` | String | `"homunculus-agent"` | MQTT client identifier |
| `allowed_topics` | Array | `["home/#", "paludarium/#", "sensors/#"]` | Topics the agent can access |
| `blocked_topics` | Array | `["home/security/#", "home/locks/#"]` | Topics that are always denied |

### `[memory]`

Persistent memory system using SQLite FTS5 and optional vector embeddings.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `backend` | String | `"sqlite"` | Storage backend |
| `db_path` | String | `"./data/memory.db"` | SQLite database path |
| `embedding_provider` | String | `"local"` | `local` (Ollama) or `anthropic` |
| `embedding_model` | String | `"nomic-embed-text"` | Embedding model name |
| `max_context_tokens` | Integer | `4096` | Max tokens to inject as memory context |

To build the memory index:

```bash
# Text search only (FTS5)
bundle exec ruby bin/homunculus memory rebuild

# Text search + vector embeddings
bundle exec ruby bin/homunculus memory rebuild --with-embeddings
```

### `[security]`

Audit and confirmation settings.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `audit_log_path` | String | `"./data/audit.jsonl"` | Path to the append-only audit log |
| `require_confirmation` | Array | `["shell_exec", "file_write", ...]` | Tools that require user confirmation before execution |

Default tools requiring confirmation: `shell_exec`, `file_write`, `send_message`, `web_fetch`, `mqtt_publish`.

### `[scheduler]`

Background task scheduler (optional).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | Boolean | `false` | Enable the scheduler |
| `db_path` | String | `"./data/scheduler.db"` | SQLite database for job persistence |

### `[scheduler.heartbeat]`

Periodic heartbeat that runs the checklist in `workspace/HEARTBEAT.md`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | Boolean | `false` | Enable heartbeat |
| `cron` | String | `"*/30 8-22 * * *"` | Cron expression (every 30 min during waking hours) |
| `model` | String | `"local"` | Model to use for heartbeat tasks |
| `active_hours_start` | Integer | `8` | Start of active hours (24h format) |
| `active_hours_end` | Integer | `22` | End of active hours |
| `timezone` | String | `"America/Sao_Paulo"` | Timezone for active hours |

### `[scheduler.notification]`

Notification delivery settings.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `max_per_hour` | Integer | `10` | Rate limit for notifications |
| `quiet_hours_queue` | Boolean | `true` | Queue notifications during quiet hours instead of dropping them |

### `[interfaces.telegram]`

Telegram bot interface.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | Boolean | `false` | Enable Telegram interface |
| `allowed_user_ids` | Array | `[]` | Telegram user IDs allowed to interact. **Required for security** -- empty means dev mode (all users allowed) |
| `session_timeout_minutes` | Integer | `30` | Inactivity timeout before session expires |
| `max_message_length` | Integer | `4096` | Max characters per Telegram message (auto-splits longer responses) |
| `typing_indicator` | Boolean | `true` | Show "typing..." indicator while processing |

The bot token is set via `TELEGRAM_BOT_TOKEN` environment variable, never in config.

## Example: Minimal Production Config

```toml
[gateway]
host = "127.0.0.1"
port = 18789

[models.local]
provider = "ollama"
base_url = "http://localhost:11434"
default_model = "qwen2.5:14b"
context_window = 32768
temperature = 0.7
timeout_seconds = 300

[models.escalation]
provider = "anthropic"
model = "claude-sonnet-4-20250514"
context_window = 200000
temperature = 0.3
daily_budget_usd = 2.0

[agent]
max_turns = 25
workspace_path = "./workspace"

[tools]
approval_mode = "elevated"

[tools.sandbox]
enabled = true

[memory]
backend = "sqlite"
db_path = "./data/memory.db"

[security]
audit_log_path = "./data/audit.jsonl"
require_confirmation = ["shell_exec", "file_write", "web_fetch", "mqtt_publish"]
```

## Ollama tuning (faster inference)

Homunculus passes `context_window` as Ollama’s `num_ctx` and caps output via `max_tokens`. To speed up local inference:

- **Context size:** Lower `context_window` in `[models.local]` (e.g. 8192) for quick chats; larger context is slower.
- **Threads:** Set `OLLAMA_NUM_THREADS` in the environment (or in the Ollama container) to match your CPU cores.
- **GPU:** Run Ollama on a machine with a GPU and enough VRAM for your model; the Docker Compose ollama profile can use NVIDIA GPUs (see [Quick Setup – GPU](QUICK_SETUP.md#gpu-acceleration-linux--nvidia-only)).
- **Timeout:** If requests time out on heavy prompts, increase `timeout_seconds` in `[models.local]` or set `OLLAMA_TIMEOUT_SECONDS` in the environment.

See [Quick Setup](QUICK_SETUP.md) for Docker and GPU setup.

## See Also

- [Quick Setup](QUICK_SETUP.md) -- getting started
- [Security Model](security.md) -- how security constraints are enforced
