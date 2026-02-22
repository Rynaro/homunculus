# Architecture

Homunculus is a multi-agent AI system designed to run on a personal home server. It prioritizes privacy (local-first inference), security (sandboxed execution), and extensibility (pluggable agents, skills, and tools).

## High-Level Overview

```
                         ┌─────────────────────────────────────────────┐
                         │              Interfaces                     │
                         │  ┌──────┐  ┌──────────┐  ┌──────────────┐  │
                         │  │ CLI  │  │ Telegram  │  │ Gateway API  │  │
                         │  └──┬───┘  └────┬─────┘  └──────┬───────┘  │
                         └─────┼───────────┼───────────────┼──────────┘
                               │           │               │
                               ▼           ▼               ▼
                         ┌─────────────────────────────────────────────┐
                         │              Agent Loop                     │
                         │  ┌────────────────────────────────────────┐ │
                         │  │  MultiAgentManager (Ractor isolation)  │ │
                         │  │  ┌─────────┐ ┌──────────┐ ┌────────┐  │ │
                         │  │  │ default │ │  coder   │ │  home  │  │ │
                         │  │  └─────────┘ └──────────┘ └────────┘  │ │
                         │  │  ┌──────────┐ ┌─────────┐             │ │
                         │  │  │researcher│ │ planner │             │ │
                         │  │  └──────────┘ └─────────┘             │ │
                         │  └────────────────────────────────────────┘ │
                         │                                             │
                         │  ┌──────────┐  ┌────────┐  ┌────────────┐  │
                         │  │  Router  │  │ Budget │  │  Prompt    │  │
                         │  │          │  │Tracker │  │  Builder   │  │
                         │  └──────────┘  └────────┘  └────────────┘  │
                         └────────┬──────────────┬────────────────────┘
                                  │              │
                    ┌─────────────┼──────────────┼─────────────┐
                    │             ▼              ▼              │
                    │  ┌──────────────┐  ┌─────────────────┐   │
                    │  │  LLM Models  │  │  Tool Registry  │   │
                    │  │ Ollama/Claude│  │  (13+ tools)    │   │
                    │  └──────────────┘  └───────┬─────────┘   │
                    │                            │             │
                    │  ┌──────────┐  ┌───────────▼──────────┐  │
                    │  │  Memory  │  │  Sandbox (Docker)    │  │
                    │  │ SQLite   │  │  No network, RO FS   │  │
                    │  │ FTS5     │  │  Drop ALL caps       │  │
                    │  └──────────┘  └──────────────────────┘  │
                    │                                          │
                    │  ┌──────────────┐  ┌──────────────────┐  │
                    │  │  Audit Log   │  │  Skills Loader   │  │
                    │  │  (JSONL)     │  │  (trigger-based) │  │
                    │  └──────────────┘  └──────────────────┘  │
                    └──────────────────────────────────────────┘
```

## Components

### Gateway (`lib/homunculus/gateway/server.rb`)

The HTTP API layer, built on Roda + Puma.

- Binds exclusively to `127.0.0.1` (enforced by runtime assertion)
- Endpoints: `POST /api/v1/chat`, `GET /api/v1/status`, `GET /health`
- Single-process mode (`workers 0`) to share agent state across requests
- Auth via bcrypt token hash

### Agent Loop (`lib/homunculus/agent/loop.rb`)

The core reasoning engine. Each request runs through a turn-based loop:

1. Build system prompt (persona + tools + memory context + skills)
2. Send messages to the LLM provider
3. If the LLM returns `end_turn` -- return the response
4. If the LLM returns `tool_use` -- execute tools and feed results back
5. Repeat up to `max_turns` (default: 25)

The loop supports both single-provider mode (CLI) and multi-provider routing mode (Telegram).

### Model Router (`lib/homunculus/agent/router.rb`)

Intelligent model selection based on task classification:

| Route to Local (Ollama) | Route to Claude |
|--------------------------|-----------------|
| Simple questions | Complex reasoning |
| Tool dispatch | Code generation/review |
| Casual chat | Multi-tool planning |
| Status checks | Document writing |
| Memory retrieval | Architecture design |
| Heartbeat tasks | Research synthesis |

The router checks the budget tracker before escalating to Claude. If the daily budget is exhausted, it falls back to the local model.

Users can override routing with `/escalate`, `/local`, or `/auto` commands.

### Budget Tracker (`lib/homunculus/agent/budget.rb`)

Tracks Anthropic API costs and enforces the daily budget limit (`daily_budget_usd` in config).

- Records per-call token usage and cost in SQLite
- Uses Claude Sonnet 4 pricing: $3/MTok input, $15/MTok output
- Exposes `can_use_claude?` for the router to check before escalating
- Resets daily (UTC)

### Multi-Agent Manager (`lib/homunculus/agent/multi_agent_manager.rb`)

Manages specialized agents, each defined by a `SOUL.md` persona in `workspace/agents/`.

**Agent routing:**
1. Explicit `@mention` -- `@coder fix this bug` routes to the coder agent
2. Content-based classification -- keyword matching against `AGENT_ROUTING_HINTS`
3. Fallback to `default` agent

**Isolation:** When `Ractor::Port` is available (Ruby 4.0+), each agent runs in its own Ractor for true memory isolation. Falls back to synchronous execution on older Ruby.

**Handoff:** Agents can hand off to each other with context summaries, enabling multi-agent collaboration.

### Agent Worker (`lib/homunculus/agent/agent_worker.rb`)

The execution unit for a single agent. Each worker:
- Holds an `AgentDefinition` (name, soul, tools config, model preference)
- Processes requests by building prompts and calling the LLM
- Runs inside a Ractor (when available) or synchronously

### Prompt Builder (`lib/homunculus/agent/prompt.rb`)

Assembles the system prompt from multiple sources:
- Agent persona (`SOUL.md`)
- Tool definitions from the registry
- Memory context (recent relevant chunks)
- Active skills (injected as XML sections)
- Workspace operating instructions (`workspace/AGENTS.md`)

### Tool Registry (`lib/homunculus/tools/registry.rb`)

Central registry for all tools. Tools are registered at boot time in the interface constructors.

**Built-in tools:**

| Tool | Description | Confirmation |
|------|-------------|-------------|
| `echo` | Echo input back (testing) | No |
| `datetime_now` | Current date/time | No |
| `workspace_read` | Read workspace files | No |
| `workspace_write` | Write workspace files | Yes |
| `workspace_list` | List workspace directory | No |
| `shell_exec` | Execute shell commands (sandboxed) | Yes |
| `web_fetch` | Fetch web pages | Yes |
| `mqtt_publish` | Publish to MQTT topics | Yes |
| `mqtt_subscribe` | Subscribe to MQTT topics | No |
| `memory_search` | Search persistent memory | No |
| `memory_save` | Save to persistent memory | No |
| `memory_daily_log` | Append to daily log | No |

Each tool extends `Tools::Base`, which provides a DSL for declaring name, description, parameters, trust level, and confirmation requirements.

### Skills Loader (`lib/homunculus/skills/loader.rb`)

Loads skill definitions from `workspace/skills/` and injects them into prompts based on message triggers.

- Skills are defined as `SKILL.md` files with YAML frontmatter
- Trigger matching: keywords in the user message activate relevant skills
- Skills are injected as `<skill>` XML sections in the system prompt
- Skills can only reference existing tools -- they cannot add new ones

### Memory System

Three components work together:

- **Store** (`lib/homunculus/memory/store.rb`) -- SQLite database with FTS5 full-text search. Stores chunks from workspace markdown files and conversation transcripts.
- **Indexer** (`lib/homunculus/memory/indexer.rb`) -- Parses markdown files into searchable chunks.
- **Embedder** (`lib/homunculus/memory/embedder.rb`) -- Computes vector embeddings via Ollama (`nomic-embed-text`) for semantic search.

### Audit Logger (`lib/homunculus/security/audit.rb`)

Append-only JSONL log of all agent actions. Thread-safe with file locking.

Each entry includes:
- Timestamp (UTC, microsecond precision)
- Action type (completion, tool_exec, session_end, etc.)
- Session ID
- Hashed inputs/outputs (SHA-256, truncated to 16 chars)
- Token counts and duration

### Sandbox (`lib/homunculus/security/sandbox.rb`)

Docker-based execution sandbox for shell commands:
- Network mode: `none` (no internet access)
- Read-only root filesystem
- All Linux capabilities dropped
- Memory limit: 512 MB, CPU limit: 1.0
- 30-second timeout per command
- Blocked command patterns checked before execution

### Scheduler (`lib/homunculus/scheduler/`)

Optional background task system:

- **Manager** -- Coordinates scheduled jobs using `rufus-scheduler`
- **JobStore** -- Persists jobs in SQLite
- **Heartbeat** -- Periodic task runner that processes `workspace/HEARTBEAT.md`
- **Notification** -- Rate-limited delivery with quiet hours support

## Request Lifecycle

A typical request through the Telegram interface:

```
1. User sends message to Telegram bot
2. Telegram interface checks authorization (allowed_user_ids)
3. Session is retrieved or created (with timeout management)
4. MultiAgentManager.detect_agent() classifies the message
   - @mention → explicit agent
   - Keywords → content-based routing
   - Default → general-purpose agent
5. Skills Loader matches triggers in the message
6. Prompt Builder assembles system prompt:
   - Agent SOUL.md + workspace AGENTS.md
   - Tool definitions
   - Memory context (FTS5 search)
   - Matched skill bodies (XML injection)
7. Router.select_model() picks Ollama or Claude:
   - Check forced_provider (user override)
   - Classify task complexity
   - Check budget for Claude
8. Agent Loop runs turn-based reasoning:
   a. Send messages to LLM
   b. If tool_use → execute tool → add result → repeat
   c. If end_turn → return response
   d. Max 25 turns
9. Response sent back to Telegram (auto-split if > 4096 chars)
10. Audit logger records completion + tool executions
11. Session updated with token usage
```

## Docker Deployment

The `docker-compose.yml` defines two services:

| Service | Purpose | Network |
|---------|---------|---------|
| `homunculus-agent` | Main application | `homunculus-net` (internal) + `telegram-egress` (outbound) |
| `homunculus-sandbox` | Tool execution sandbox | `none` (isolated) |

The agent container:
- Runs as non-root user (`homunculus`, UID 1000)
- Mounts `workspace/` as a volume for persistence
- Uses a named volume for `data/`
- Exposes port 18789 on `127.0.0.1` only
- Has `no-new-privileges` security option

## See Also

- [Configuration Reference](configuration.md) -- all settings
- [Workspace Customization](workspace.md) -- agents and skills
- [Security Model](security.md) -- defense in depth
