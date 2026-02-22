# Security Model

Homunculus follows a defense-in-depth approach. No single layer is trusted alone -- multiple independent mechanisms enforce safety at every stage of request processing.

## Principles

1. **Local-only by default** -- the gateway never binds to a public address
2. **Least privilege** -- tools run in sandboxed containers with no capabilities
3. **Explicit confirmation** -- destructive operations require user approval
4. **Append-only audit** -- every action is logged and cannot be retroactively modified
5. **Secrets out of config** -- credentials live in environment variables, never in files

## Gateway Security

### Bind Address Enforcement

The gateway is hardcoded to bind to `127.0.0.1`. This is enforced by a runtime assertion in `GatewayConfig#validate!` (`lib/homunculus/config.rb`):

```ruby
def validate!
  raise SecurityError, "Gateway MUST bind to 127.0.0.1, got #{host}" unless host == '127.0.0.1'
end
```

The server will refuse to start if any other address is configured. This cannot be overridden by environment variables or config changes -- it is a code-level constraint.

### Authentication

The gateway uses bcrypt token authentication. The token hash is stored in `GATEWAY_AUTH_TOKEN_HASH` (environment variable). The plaintext token is generated once during `scripts/setup.sh` and never stored.

### Docker Network Isolation

In Docker deployment, the agent container runs on two networks:

| Network | Type | Purpose |
|---------|------|---------|
| `homunculus-net` | `internal: true` | No external access. Agent-to-sandbox communication |
| `telegram-egress` | `bridge` | Outbound-only access to Telegram API |

The port mapping is explicitly bound to localhost: `127.0.0.1:18789:18789`.

## Sandbox

Shell commands executed by the agent run inside a Docker container with maximum isolation.

### Sandbox Configuration

| Setting | Value | Purpose |
|---------|-------|---------|
| Network | `none` | No network access whatsoever |
| Root filesystem | Read-only | Cannot modify the container |
| Capabilities | Drop `ALL` | No Linux capabilities |
| `no-new-privileges` | `true` | Cannot escalate privileges |
| Memory limit | 512 MB | Prevent resource exhaustion |
| CPU limit | 1.0 | Prevent CPU starvation |
| Timeout | 30 seconds | Kill long-running commands |
| tmpfs | `/tmp` (50 MB, noexec) | Temporary storage only |
| Workspace mount | Read-only | Can read but not modify workspace |

### Command Filtering

Before any command reaches the sandbox, it is checked against blocked patterns:

```
rm -rf /
mkfs
dd if=
> /dev/
```

Commands matching these patterns are rejected with a `SecurityError` before execution.

### Safe Commands

The `safe_commands` list in config defines commands that skip the confirmation prompt (but still run in the sandbox):

```
ls, cat, grep, find, wc, head, tail, date, echo, pwd
```

All other commands require user confirmation when `approval_mode` is set to `elevated`.

### Sandbox Bypass

When `tools.sandbox.enabled` is `false`, commands run directly on the host. This is logged as a warning. Only disable the sandbox in development environments.

## Tool Confirmation

Tools listed in `security.require_confirmation` must be explicitly approved by the user before execution.

**Default tools requiring confirmation:**
- `shell_exec` -- arbitrary command execution
- `file_write` -- filesystem modifications
- `send_message` -- outbound communication
- `web_fetch` -- network requests
- `mqtt_publish` -- device actuation

### Confirmation Flow

**CLI:**
1. Agent requests a tool call
2. CLI displays the tool name and arguments
3. User types `confirm` or `deny`
4. Tool executes (or is rejected) and the loop continues

**Telegram:**
1. Agent requests a tool call
2. Bot sends an inline keyboard with Confirm/Deny buttons
3. User taps a button
4. Callback is processed and the loop continues

### Approval Modes

| Mode | Behavior |
|------|----------|
| `off` | No confirmations -- all tools execute immediately |
| `elevated` | Only tools in `require_confirmation` need approval |
| `always` | Every tool call requires approval |

## Audit Log

All agent actions are recorded in an append-only JSONL file at `data/audit.jsonl`.

### Log Entry Format

```json
{
  "ts": "2026-02-14T12:00:00.000000Z",
  "session_id": "uuid",
  "action": "tool_exec",
  "tool": "shell_exec",
  "input_hash": "a1b2c3d4e5f6g7h8",
  "output_hash": "i9j0k1l2m3n4o5p6",
  "confirmed": true,
  "model": "qwen2.5:14b",
  "duration_ms": 1234
}
```

### What is Logged

| Action | Fields |
|--------|--------|
| `completion` | model, tokens_in, tokens_out, stop_reason, duration_ms |
| `tool_exec` | tool name, input_hash, output_hash, confirmed, duration_ms |
| `session_end` | turn_count, total tokens, duration |
| `session_expired` | session_id, chat_id |
| `unauthorized_access` | user_id |

### Privacy

Inputs and outputs are **hashed** (SHA-256, truncated to 16 characters) before logging. The audit log records that an action happened and its metadata, but not the actual content. This allows forensic analysis without storing sensitive data.

### Thread Safety

The audit logger uses a `Mutex` and `File.flock(LOCK_EX)` for thread-safe, atomic writes. Multiple concurrent sessions can safely write to the same log file.

## MQTT Security

### Topic Allowlists

The MQTT configuration defines which topics the agent can access:

```toml
allowed_topics = ["home/#", "sensors/#"]
blocked_topics = ["home/security/#", "home/locks/#"]
```

Blocked topics take precedence over allowed topics. The agent cannot interact with security systems or door locks under any circumstances.

### Credential Management

MQTT credentials are set via environment variables (`MQTT_USERNAME`, `MQTT_PASSWORD`), never in the config file.

## Telegram Security

### User Allowlist

The `allowed_user_ids` setting restricts who can interact with the bot:

```toml
[interfaces.telegram]
allowed_user_ids = [123456789]  # Your Telegram user ID
```

When the list is empty, all users are allowed (development mode). In production, always set explicit user IDs.

Unauthorized access attempts are silently rejected and logged to the audit trail.

### Session Isolation

Each Telegram chat gets its own `Session` object with independent:
- Message history
- Token counters
- Active agent
- Enabled skills
- Forced provider setting

Sessions expire after `session_timeout_minutes` (default: 30) of inactivity.

## Credential Storage

| Credential | Storage | Never In |
|------------|---------|----------|
| Gateway auth token hash | `GATEWAY_AUTH_TOKEN_HASH` env var | Config file |
| Anthropic API key | `ANTHROPIC_API_KEY` env var | Config file |
| Telegram bot token | `TELEGRAM_BOT_TOKEN` env var | Config file |
| MQTT username | `MQTT_USERNAME` env var | Config file |
| MQTT password | `MQTT_PASSWORD` env var | Config file |

The `.env` file is listed in `.env.example` as a template. The actual `.env` must never be committed to version control.

## Docker Container Security

The main application container (`homunculus-agent`) runs with:

- Non-root user: `homunculus` (UID 1000)
- `no-new-privileges` security option
- tmpfs for `/tmp` (100 MB limit)
- Named volume for persistent data (not bind-mounted to host root)

The sandbox container (`homunculus-sandbox`) has even stricter settings -- see the Sandbox section above.

## See Also

- [Configuration Reference](configuration.md) -- security-related settings
- [Architecture](architecture.md) -- how security components integrate
