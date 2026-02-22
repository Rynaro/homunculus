# Development Guide

This guide covers the project structure, testing, boot sequence, and how to extend Homunculus with new tools, agents, and skills.

## Project Structure

```
homunculus/
├── bin/
│   ├── homunculus              # Main entry point (CLI dispatcher)
│   └── console                 # IRB console with app loaded
├── config/
│   ├── boot.rb                 # Bootstrap: requires all modules in order
│   └── default.toml            # Default configuration
├── lib/homunculus/
│   ├── version.rb              # VERSION constant
│   ├── config.rb               # Config loading + typed structs (dry-struct)
│   ├── session.rb              # Per-conversation session state
│   ├── agent/
│   │   ├── loop.rb             # Core reasoning loop (turn-based)
│   │   ├── models.rb           # LLM provider abstraction
│   │   ├── prompt.rb           # System prompt builder
│   │   ├── router.rb           # Intelligent model selection
│   │   ├── budget.rb           # API cost tracking + daily limits
│   │   ├── agent_definition.rb # Data class for agent persona
│   │   ├── agent_worker.rb     # Execution unit per agent (Ractor-compatible)
│   │   └── multi_agent_manager.rb  # Agent orchestration + routing
│   ├── gateway/
│   │   └── server.rb           # Roda + Puma HTTP API
│   ├── interfaces/
│   │   ├── cli.rb              # Interactive terminal interface
│   │   └── telegram.rb         # Telegram bot interface
│   ├── tools/
│   │   ├── base.rb             # Tool base class + DSL
│   │   ├── registry.rb         # Tool registration + execution
│   │   ├── echo.rb             # Echo tool (testing)
│   │   ├── datetime_now.rb     # Current time
│   │   ├── workspace_read.rb   # Read workspace files
│   │   ├── workspace_write.rb  # Write workspace files
│   │   ├── workspace_list.rb   # List workspace directory
│   │   ├── shell.rb            # Shell command execution (sandboxed)
│   │   ├── web.rb              # Web page fetching
│   │   ├── files.rb            # File operations
│   │   ├── mqtt.rb             # MQTT publish/subscribe
│   │   ├── memory_search.rb    # Search persistent memory
│   │   ├── memory_save.rb      # Save to memory
│   │   └── memory_daily_log.rb # Daily log entries
│   ├── memory/
│   │   ├── store.rb            # SQLite + FTS5 memory store
│   │   ├── indexer.rb          # Markdown → searchable chunks
│   │   └── embedder.rb         # Vector embeddings via Ollama
│   ├── security/
│   │   ├── audit.rb            # Append-only JSONL audit logger
│   │   └── sandbox.rb          # Docker sandbox for command execution
│   ├── skills/
│   │   ├── skill.rb            # Skill data class + YAML parser
│   │   └── loader.rb           # Skill discovery, matching, injection
│   ├── scheduler/
│   │   ├── manager.rb          # Job scheduling (rufus-scheduler)
│   │   ├── job_store.rb        # SQLite job persistence
│   │   ├── heartbeat.rb        # Periodic heartbeat runner
│   │   └── notification.rb     # Rate-limited notification delivery
│   └── utils/
│       └── logging.rb          # SemanticLogger mixin
├── workspace/                  # Runtime workspace (agents, skills, memory)
├── spec/                       # RSpec test suite
├── scripts/
│   └── setup.sh                # First-run setup script
├── data/                       # Runtime data (SQLite DBs, audit log)
├── agents/                     # APIVR-Δ methodology (Cursor/IDE agent rules)
├── Gemfile                     # Ruby dependencies
├── Dockerfile                  # Main application container
├── Dockerfile.sandbox          # Sandbox container
└── docker-compose.yml          # Multi-container deployment
```

## Prerequisites

- Ruby >= 3.4 (4.0 recommended for Ractor support)
- Bundler
- SQLite3 development headers (`libsqlite3-dev`)
- Docker (for sandbox and containerized deployment)

## Getting Started

```bash
# Install dependencies
bundle install

# Run the test suite
bundle exec rspec

# Run with documentation format
bundle exec rspec --format documentation

# Run a specific spec file
bundle exec rspec spec/agent/router_spec.rb

# Validate configuration
bundle exec ruby bin/homunculus validate

# Interactive console
bundle exec ruby bin/console
```

## Boot Sequence

The application bootstraps via `config/boot.rb`, which:

1. Loads Bundler and dotenv
2. Configures SemanticLogger (JSON format to stdout)
3. Requires all modules in dependency order

The require order matters -- modules are loaded bottom-up so that dependencies are available when needed. The full sequence:

```
version → config → logging → session → security → tools → memory → agent → skills → scheduler → gateway → interfaces
```

Each interface (CLI, Telegram, Gateway) builds its own component graph at initialization time, wiring together the config, providers, tools, memory, audit, and agent loop.

## Adding a New Tool

Tools extend `Homunculus::Tools::Base` and use a class-level DSL.

### 1. Create the tool class

Create `lib/homunculus/tools/my_tool.rb`:

```ruby
# frozen_string_literal: true

module Homunculus
  module Tools
    class MyTool < Base
      tool_name "my_tool"
      description "Does something useful"
      requires_confirmation false
      trust_level :trusted

      parameter :input, type: :string, description: "The input value", required: true
      parameter :format, type: :string, description: "Output format", required: false,
                         enum: %w[json text]

      def initialize(config: nil)
        @config = config
      end

      def execute(arguments:, session:)
        input = arguments[:input]
        # ... do work ...
        Result.ok("Result: #{input}")
      rescue StandardError => e
        Result.fail(e.message)
      end
    end
  end
end
```

**DSL methods:**

| Method | Purpose |
|--------|---------|
| `tool_name` | Unique identifier (defaults to snake_case of class name) |
| `description` | Human-readable description for the LLM |
| `requires_confirmation` | Whether the tool needs user approval |
| `trust_level` | `:trusted` or `:untrusted` |
| `parameter` | Declare a parameter with type, description, required, and optional enum |

**Return values:** Always return `Result.ok(output)` or `Result.fail(error)`.

### 2. Register the tool in boot

Add the require to `config/boot.rb`:

```ruby
require_relative "../lib/homunculus/tools/my_tool"
```

### 3. Register in interface constructors

Add registration in the `build_tool_registry` method of each interface that should have the tool (`lib/homunculus/interfaces/cli.rb` and `lib/homunculus/interfaces/telegram.rb`):

```ruby
registry.register(Tools::MyTool.new(config: @config))
```

### 4. Write specs

Create `spec/tools/my_tool_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Homunculus::Tools::MyTool do
  subject(:tool) { described_class.new }

  let(:session) { Homunculus::Session.new }

  describe "#execute" do
    it "returns a successful result" do
      result = tool.execute(arguments: { input: "hello" }, session: session)
      expect(result.success).to be true
      expect(result.output).to include("hello")
    end
  end
end
```

### 5. (Optional) Restrict to specific agents

If the tool should only be available to certain agents, add it to their `TOOLS.md`:

```markdown
## Allowed Tools
- `my_tool` -- Description of what it does
```

## Adding a New Agent

No code changes required. Agents are defined entirely in the workspace.

### 1. Create the agent directory

```bash
mkdir -p workspace/agents/myagent
```

### 2. Write SOUL.md

Create `workspace/agents/myagent/SOUL.md`:

```markdown
# My Agent

## Identity
You are Homunculus in myagent mode -- a specialist for <domain>.

## Expertise
- Area 1
- Area 2

## Behavior
- How to act
- What to prioritize

## Response Format
- Formatting preferences

## Model Preference
Prefer local model for <simple tasks>. Escalate to Claude for <complex tasks>.
```

### 3. (Optional) Write TOOLS.md

Create `workspace/agents/myagent/TOOLS.md` to restrict tool access:

```markdown
# My Agent -- Tool Configuration

## Allowed Tools
- `tool_name` -- What it does

## Tool Usage Guidelines
- Specific instructions for this agent
```

### 4. Restart

The `MultiAgentManager` scans `workspace/agents/` at startup. Restart Homunculus to pick up the new agent.

### 5. Test routing

Use `@myagent` in a message to route to your agent, or add keywords to `AGENT_ROUTING_HINTS` in `multi_agent_manager.rb` for automatic content-based routing.

## Adding a New Skill

Skills are also code-free -- defined entirely in the workspace.

### 1. Create the skill directory

```bash
mkdir -p workspace/skills/myskill
```

### 2. Write SKILL.md

Create `workspace/skills/myskill/SKILL.md`:

```markdown
---
name: myskill
description: "What this skill provides"
tools_required: [tool_name_1, tool_name_2]
model_preference: auto
auto_activate: false
triggers: ["keyword1", "keyword2"]
---

# My Skill

Instructions and reference data for the agent when this skill is active.
```

### 3. (Optional) Add supporting files

You can include additional files in the skill directory (e.g., `thresholds.toml`, reference data). These are not automatically loaded but can be referenced in the skill body.

### 4. Restart and verify

Restart Homunculus. Use `/skills` in Telegram or check the logs to verify the skill loaded.

## Test Suite

The test suite uses RSpec with the following conventions:

- Specs mirror the `lib/` structure under `spec/`
- `spec/spec_helper.rb` loads all modules and suppresses logging
- Partial double verification is enabled
- Monkey patching is disabled
- Tests run in random order

### Running Tests

```bash
# Full suite
bundle exec rspec

# With documentation format
bundle exec rspec --format documentation

# Specific file
bundle exec rspec spec/agent/router_spec.rb

# Specific test by line number
bundle exec rspec spec/agent/router_spec.rb:15

# Only focused tests (add `focus: true` to a describe/it block)
bundle exec rspec --tag focus
```

### Test Coverage by Module

| Module | Spec File |
|--------|-----------|
| Config | `spec/config_spec.rb` |
| Session | `spec/session_spec.rb` |
| Agent Loop | `spec/agent/loop_spec.rb` |
| Router | `spec/agent/router_spec.rb` |
| Budget | `spec/agent/budget_spec.rb` |
| Prompt | `spec/agent/prompt_spec.rb` |
| Models | `spec/agent/models_spec.rb` |
| MultiAgentManager | `spec/agent/multi_agent_manager_spec.rb` |
| Tool Registry | `spec/tools/registry_spec.rb` |
| Tools (general) | `spec/tools/tools_spec.rb` |
| Shell Tool | `spec/tools/shell_spec.rb` |
| Web Tool | `spec/tools/web_spec.rb` |
| Files Tool | `spec/tools/files_spec.rb` |
| MQTT Tool | `spec/tools/mqtt_spec.rb` |
| Memory Tools | `spec/tools/memory_tools_spec.rb` |
| Memory Store | `spec/memory/store_spec.rb` |
| Memory Indexer | `spec/memory/indexer_spec.rb` |
| Memory Embedder | `spec/memory/embedder_spec.rb` |
| Audit | `spec/security/audit_spec.rb` |
| Skill | `spec/skills/skill_spec.rb` |
| Skill Loader | `spec/skills/loader_spec.rb` |
| Scheduler Manager | `spec/scheduler/manager_spec.rb` |
| Scheduler JobStore | `spec/scheduler/job_store_spec.rb` |
| Scheduler Heartbeat | `spec/scheduler/heartbeat_spec.rb` |
| Scheduler Notification | `spec/scheduler/notification_spec.rb` |
| Telegram Interface | `spec/interfaces/telegram_spec.rb` |

## Linting

```bash
bundle exec rubocop

# Auto-fix safe corrections
bundle exec rubocop -a
```

## Key Dependencies

| Gem | Purpose |
|-----|---------|
| `roda` | HTTP routing (Gateway) |
| `puma` | Web server |
| `toml-rb` | TOML config parsing |
| `dry-struct` / `dry-types` | Typed configuration structs |
| `httpx` | HTTP client (LLM API calls, web fetching) |
| `sequel` + `sqlite3` | Database (memory, budget, scheduler) |
| `semantic_logger` | Structured JSON logging |
| `bcrypt` | Auth token hashing |
| `oj` | Fast JSON serialization |
| `nokogiri` | HTML parsing (web tool) |
| `mqtt` | MQTT client |
| `telegram-bot-ruby` | Telegram Bot API |
| `rufus-scheduler` | Cron-based job scheduling |

## Note on `agents/` vs `workspace/agents/`

The repository contains two separate "agents" directories:

- **`agents/`** (repo root) -- The APIVR-Delta methodology for Cursor/IDE coding agents. This is a development-time tool for AI-assisted coding, not part of the Homunculus runtime.
- **`workspace/agents/`** -- Runtime agent personas that Homunculus loads and uses to handle user messages.

These are independent systems. Modifying one does not affect the other.

## See Also

- [Architecture](architecture.md) -- component overview and data flow
- [Workspace](workspace.md) -- agent and skill customization
- [Configuration](configuration.md) -- all settings
