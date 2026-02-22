# Interfaces

Homunculus provides three ways to interact: a Gateway HTTP API, an interactive CLI, and a Telegram bot. All three share the same agent loop, tools, and memory system.

## Gateway API

The HTTP API is the primary programmatic interface. It runs on Roda + Puma, bound to `127.0.0.1:18789`.

### Endpoints

#### `POST /api/v1/chat`

Send a message to the agent and receive a response.

**Request:**

```json
{
  "message": "What time is it?"
}
```

**Response:**

```json
{
  "response": "The current time is 2026-02-14 15:30:00 -0300."
}
```

**Error (400):**

```json
{
  "error": "message is required"
}
```

#### `GET /api/v1/status`

Check server status.

**Response:**

```json
{
  "status": "running",
  "version": "0.1.0",
  "uptime_seconds": 3600
}
```

#### `GET /health`

Health check endpoint (provided by Roda's heartbeat plugin). Returns `200 OK` with an empty body. Useful for load balancers and monitoring.

### Starting the Gateway

```bash
# Docker
docker compose up -d

# Local
bundle exec ruby bin/homunculus serve
```

The gateway runs as a single-process Puma server (no workers) to maintain shared agent state across requests.

## CLI

The interactive CLI provides a terminal-based chat interface with the agent.

### Starting the CLI

```bash
# Default: local Ollama model
bundle exec ruby bin/homunculus cli

# Use Anthropic (escalation model)
bundle exec ruby bin/homunculus cli --provider escalation

# Override the specific model
bundle exec ruby bin/homunculus cli --provider local --model llama3:8b
```

### CLI Commands

| Command | Description |
|---------|-------------|
| `help` | Show available commands and registered tools |
| `status` | Display session info: ID, turns, tokens, duration, provider |
| `confirm` | Approve a pending tool action |
| `deny` | Reject a pending tool action |
| `quit` / `exit` | End the session and exit |

### Session Lifecycle

1. On start, the CLI prints a banner with the model name and provider
2. A new `Session` is created automatically
3. Each message is processed through the agent loop
4. Tool calls that require confirmation pause the loop until `confirm` or `deny`
5. On exit, the session is summarized and saved to memory (if memory is available)
6. Token usage summary is printed

### Token Display

After each response, the CLI shows token usage:

```
[tokens: 1234↓ 567↑ | turns: 3]
```

- `↓` = input tokens consumed
- `↑` = output tokens generated

## Telegram Bot

The Telegram interface is the richest interaction mode, with multi-agent routing, skill management, budget tracking, and inline confirmation buttons.

### Setup

1. Create a bot via [@BotFather](https://t.me/BotFather) on Telegram
2. Set the bot token:
   ```bash
   # In .env
   TELEGRAM_BOT_TOKEN=your-bot-token-here
   ```
3. Find your Telegram user ID (send `/start` to [@userinfobot](https://t.me/userinfobot))
4. Add your user ID to the config:
   ```toml
   [interfaces.telegram]
   enabled = true
   allowed_user_ids = [123456789]
   ```
5. Start the bot:
   ```bash
   bundle exec ruby bin/homunculus telegram
   
   # Or with a specific default provider
   bundle exec ruby bin/homunculus telegram --provider local
   ```

### Telegram Commands

| Command | Description |
|---------|-------------|
| `/start` | Welcome message with all available commands |
| `/new` | Start a fresh session (saves and closes the current one) |
| `/memory <query>` | Search persistent memory |
| `/status` | Session info, active agent, enabled skills, token usage |
| `/escalate` | Force Claude for the current session |
| `/local` | Force local model for the current session |
| `/auto` | Return to automatic model routing |
| `/budget` | Show daily API spend and remaining budget |
| `/scheduler` | Scheduler status and job list |
| `/agents` | List available agents with descriptions |
| `/skills` | List available skills with trigger keywords |
| `/enable <skill>` | Enable a skill for the current session |
| `/disable <skill>` | Disable a skill for the current session |

### Agent Routing via Telegram

Use `@agent_name` at the start of a message to route to a specific agent:

```
@coder fix the bug in lib/homunculus/config.rb
@researcher compare Redis vs Memcached for session storage
@home check the paludarium temperature
@planner plan the weekend tasks
```

Without an explicit mention, the bot automatically routes based on message content.

### Tool Confirmation in Telegram

When a tool requires confirmation, the bot sends an inline keyboard:

```
⚠️ Action requires confirmation:

Tool: shell_exec
Arguments: {"command": "git status"}

[✅ Confirm]  [❌ Deny]
```

Tap a button to approve or reject. The agent loop resumes with the result.

### Session Management

- Each Telegram chat gets an independent session
- Sessions expire after 30 minutes of inactivity (configurable via `session_timeout_minutes`)
- Expired sessions are automatically saved to memory
- Use `/new` to manually start a fresh session

### Message Handling

- Long responses are automatically split at paragraph/line/word boundaries to stay within Telegram's 4096-character limit
- Markdown formatting is used when possible, with automatic fallback to plain text if parsing fails
- Typing indicators are shown while the agent processes (configurable via `typing_indicator`)

### Notifications

When the scheduler is enabled, Homunculus can proactively send notifications to all allowed users:

- Heartbeat alerts (sensor out of range, reminders)
- High-priority notifications are prefixed with a priority indicator
- Rate-limited to `max_per_hour` (default: 10)
- Queued during quiet hours if `quiet_hours_queue` is enabled

## Memory Commands

Available from the main CLI entry point (not inside a chat session):

```bash
# Rebuild the FTS5 index from workspace markdown files
bundle exec ruby bin/homunculus memory rebuild

# Rebuild with vector embeddings (requires Ollama + nomic-embed-text)
bundle exec ruby bin/homunculus memory rebuild --with-embeddings

# Show memory system status
bundle exec ruby bin/homunculus memory status
```

**Memory status output:**

```
Memory Status:
  Database:   ./data/memory.db (524288 bytes)
  Chunks:     142
  Sources:    12 files
  Embeddings: 142
  Embedder:   available
```

## Validate Command

Check that your configuration is valid without starting a server:

```bash
bundle exec ruby bin/homunculus validate
```

**Output:**

```
✓ Configuration valid
  Gateway: 127.0.0.1:18789
  Local model: qwen2.5:14b
  Escalation model: claude-sonnet-4-20250514
  Workspace: ./workspace
```

## Version

```bash
bundle exec ruby bin/homunculus version
```

## See Also

- [Quick Setup](QUICK_SETUP.md) -- getting started
- [Configuration](configuration.md) -- interface settings
- [Workspace](workspace.md) -- agents and skills management
- [Security](security.md) -- authentication and authorization
