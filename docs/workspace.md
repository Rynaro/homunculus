# Workspace Customization

The `workspace/` directory is where you define Homunculus's personality, capabilities, and domain knowledge. It is the primary customization surface -- no Ruby code changes needed.

## Workspace Layout

```
workspace/
├── AGENTS.md                          # Operating instructions (response protocol, tool rules)
├── HEARTBEAT.md                       # Checklist for scheduled heartbeat tasks
├── agents/                            # Agent personas
│   ├── default/SOUL.md                # General-purpose assistant
│   ├── coder/
│   │   ├── SOUL.md                    # Coder persona
│   │   └── TOOLS.md                   # Allowed tools + usage guidelines
│   ├── researcher/
│   │   ├── SOUL.md                    # Research specialist
│   │   └── TOOLS.md
│   ├── home/
│   │   ├── SOUL.md                    # Home automation specialist
│   │   └── TOOLS.md                   # MQTT topics + device inventory
│   └── planner/
│       ├── SOUL.md                    # Planning & task management
│       └── TOOLS.md
├── skills/                            # Pluggable domain knowledge
│   ├── paludarium_monitor/
│   │   ├── SKILL.md                   # Skill definition + instructions
│   │   └── thresholds.toml            # Sensor threshold config
│   └── git_workflow/
│       └── SKILL.md                   # Git conventions + workflow
└── memory/                            # Agent memory files (auto-managed)
```

## Agents

Each agent is a directory under `workspace/agents/` containing at minimum a `SOUL.md` file.

### SOUL.md

The persona file defines who the agent is, what it knows, and how it behaves. It is injected as part of the system prompt when the agent handles a request.

**Structure:**

```markdown
# Agent Name

## Identity
You are Homunculus in <mode> mode -- <one-line description>.

## Expertise
- Domain area 1
- Domain area 2

## Behavior
- How the agent should act
- What it should prioritize

## Response Format
- Formatting preferences
- Output structure

## Model Preference
Prefer local model for <simple tasks>. Escalate to Claude for <complex tasks>.
```

**Model preference** is extracted from the SOUL.md content. Valid values:
- `local` -- always use Ollama
- `escalation` -- always use Claude
- `auto` (default) -- let the router decide

### TOOLS.md (optional)

Restricts which tools an agent can use and provides tool-specific guidelines.

**Example** (`workspace/agents/coder/TOOLS.md`):

```markdown
# Coder Agent -- Tool Configuration

## Allowed Tools
- `shell_exec` -- Run commands in sandbox
- `workspace_read` -- Read source files
- `workspace_write` -- Write/modify source files
- `workspace_list` -- Browse project structure
- `web_fetch` -- Look up documentation
- `memory_search` -- Recall past coding decisions
- `memory_save` -- Record architectural decisions

## Tool Usage Guidelines
- Always use `workspace_list` before modifying unfamiliar directories
- Read a file before editing it
- Run tests after making changes when possible
```

### Built-in Agents

| Agent | Specialty | Model Preference | Key Tools |
|-------|-----------|-----------------|-----------|
| `default` | General-purpose assistant | auto | All basic tools |
| `coder` | Code generation, review, debugging | Prefers Claude | shell_exec, workspace_*, web_fetch |
| `researcher` | Research, analysis, synthesis | Prefers Claude | web_fetch, memory_* |
| `home` | Home automation via MQTT | Prefers local | mqtt_*, memory_*, datetime_now |
| `planner` | Task management, scheduling | auto | memory_*, workspace_* |

### Agent Routing

Messages are routed to agents in three ways:

1. **Explicit @mention:** `@coder fix this bug` routes directly to the coder agent
2. **Content-based:** Keywords in the message are matched against routing hints (e.g., "mqtt", "sensor" routes to `home`)
3. **Fallback:** Unmatched messages go to the `default` agent

### Creating a New Agent

1. Create a directory: `workspace/agents/myagent/`
2. Add `SOUL.md` with the persona definition
3. Optionally add `TOOLS.md` to restrict tool access
4. Restart Homunculus -- agents are loaded at startup

No code changes required. The `MultiAgentManager` discovers agents by scanning `workspace/agents/` for directories containing `SOUL.md`.

## Skills

Skills are pluggable domain knowledge modules that activate based on message content. Unlike agents (which are personas), skills inject additional context and instructions into whatever agent is handling the request.

### SKILL.md Format

Each skill lives in `workspace/skills/<name>/SKILL.md` and uses YAML frontmatter followed by a Markdown body:

```markdown
---
name: my_skill
description: "What this skill does"
tools_required: [tool_name_1, tool_name_2]
model_preference: local
auto_activate: false
triggers: ["keyword1", "keyword2", "phrase to match"]
---

# Skill Title

Instructions, reference data, and guidelines for the agent
when this skill is active.
```

**Frontmatter fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | String | Yes | Unique skill identifier |
| `description` | String | No | Human-readable description |
| `tools_required` | Array | No | Tools this skill needs (validated against registry) |
| `model_preference` | String | No | `local`, `escalation`, or `auto` (default) |
| `auto_activate` | Boolean | No | If `true`, always active without needing triggers |
| `triggers` | Array | No | Keywords/phrases that activate this skill |

### How Skills Work

1. User sends a message
2. The Skills Loader checks all trigger keywords against the message
3. Matching skills are scored by relevance (trigger count, specificity, position)
4. Matched skills are injected into the system prompt as XML:

```xml
<active_skills>
<skill name="paludarium_monitor" description="Monitor paludarium via MQTT">
  ...skill body...
</skill>
</active_skills>
```

5. The agent sees the skill context and follows its instructions

### Built-in Skills

**paludarium_monitor** -- Monitors a paludarium environment via MQTT sensors.
- Triggers: `paludarium`, `terrarium`, `humidity`, `pH`, `sensor`, etc.
- Auto-activate: `true`
- Tools: `mqtt_subscribe`, `mqtt_publish`, `memory_save`
- Includes sensor topics, thresholds, and corrective actions
- Has a companion `thresholds.toml` for sensor limits

**git_workflow** -- Git conventions and workflow guidelines.
- Triggers: `git`, `commit`, `branch`, `merge`, `pull request`, etc.
- Auto-activate: `false`
- Tools: `shell_exec`, `workspace_read`, `workspace_write`
- Covers conventional commits, branch naming, PR guidelines

### Creating a New Skill

1. Create a directory: `workspace/skills/myskill/`
2. Add `SKILL.md` with YAML frontmatter and instructions
3. Optionally add supporting files (thresholds, reference data)
4. Restart Homunculus or use the `/skills` command to verify

Skills can reference existing registered tools but cannot add new ones. They also cannot modify agent personas or override security confirmations.

### Managing Skills at Runtime

Via Telegram:
- `/skills` -- list all skills with their status
- `/enable <name>` -- enable a skill for the current session
- `/disable <name>` -- disable a skill

Auto-activated skills are always on and cannot be disabled.

## HEARTBEAT.md

The heartbeat checklist (`workspace/HEARTBEAT.md`) defines tasks that run periodically when the scheduler is enabled.

```markdown
# Heartbeat Checklist

## Paludarium Monitoring
- [ ] Check water temperature sensor (topic: paludarium/sensors/water_temp)
  - Alert if below 22C or above 28C
- [ ] Check humidity sensor (topic: paludarium/sensors/humidity)
  - Alert if below 70% or above 95%

## Daily Reminders (weekdays only)
- [ ] Remind about daily standup at 8:50 AM BRT

## Weekly Tasks (Monday only)
- [ ] Remind about weekly water change for paludarium
```

The heartbeat runs on a cron schedule (default: every 30 minutes during active hours). The agent processes each checklist item and sends notifications via the configured interface (Telegram).

## workspace/AGENTS.md

This file contains operating instructions that apply to all agents. It defines the response protocol, tool usage rules, error handling, and context management guidelines. It is always included in the system prompt regardless of which agent is active.

## See Also

- [Architecture](architecture.md) -- how agents, skills, and tools interact
- [Configuration](configuration.md) -- scheduler and heartbeat settings
- [Interfaces](interfaces.md) -- Telegram commands for skill/agent management
