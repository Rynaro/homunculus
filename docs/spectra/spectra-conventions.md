# SPECTRA Conventions — humunculus

> Maps SPECTRA's generic vocabulary to this project's conventions so that generated specs use the right paths, names, and patterns.

---

## Quick Reference

1. **Core logic** lives in `lib/homunculus/` under domain modules: `agent/`, `tools/`, `gateway/`, `memory/`, `scheduler/`, `security/`. No standalone "Service" classes; use agent components or tool classes.
2. **API surface** is Roda in `lib/homunculus/gateway/server.rb`; routes live under `api/v1` (e.g. `r.get "status"`). Add endpoints there; keep gateway bound to `127.0.0.1`.
3. **Tests** are RSpec: `spec/**/*_spec.rb` mirroring `lib/homunculus/` (e.g. `lib/homunculus/agent/loop.rb` → `spec/agent/loop_spec.rb` or `spec/homunculus/agent/loop_spec.rb`). Coverage: 75% overall, 30% per file.
4. **Config** is TOML + Dry::Struct in `config/default.toml` and `lib/homunculus/config.rb`. No separate schema files; validation lives in structs and `validate!` methods.
5. **Risk gates** are non-negotiable: no secrets in repo, audit log append-only, sandbox enabled, gateway localhost-only, MQTT blocked topics unchanged. Every SPECTRA spec must respect CLAUDE.md risk gates.

---

## 1. Convention Mapping

| SPECTRA Concept | Generic Example | My Convention | Path Pattern |
|-----------------|-----------------|---------------|--------------|
| Service / Business Logic | `UserRegistrationService` | Agent component or Tool class | `lib/homunculus/agent/*.rb`, `lib/homunculus/tools/*.rb` |
| Data Access / Repository | `UserRepository` | Store / Indexer | `lib/homunculus/memory/store.rb`, `lib/homunculus/memory/indexer.rb` |
| Schema / Validation | `UserSchema` | Config struct (Dry::Struct) | `lib/homunculus/config.rb`, `config/default.toml` |
| UI Component | `UserProfile` | Interface (CLI, TUI, Telegram) | `lib/homunculus/interfaces/*.rb` |
| Background Job | `ImportJob` | Scheduler job (e.g. Heartbeat) | `lib/homunculus/scheduler/*.rb` |
| API Endpoint | `POST /users` | Roda route under `api/v1` | `lib/homunculus/gateway/server.rb` (e.g. `r.get "status"`) |
| Database Migration | `add_users_table` | Not used | N/A (internal SQLite for memory only) |
| Test File | `user.test.ts` | RSpec spec | `spec/**/*_spec.rb` (mirror `lib/homunculus/` layout) |

---

## 2. Action Verb Mapping

| Verb | In My Project | Example |
|------|----------------|---------|
| Create | Add a new class/file under the right module | "Create `Homunculus::Tools::MyTool` at `lib/homunculus/tools/my_tool.rb`" |
| Extend | Add behaviour to an existing class or route block | "Extend `Gateway::Server` with `r.get 'health'`" |
| Modify | Change existing implementation or config | "Modify `config/default.toml` to add `[gateway.health_path]`" |
| Test | RSpec examples | "Test with `spec/gateway/server_spec.rb` covering status and version" |
| Configure | TOML + struct attributes | "Configure gateway in `config/default.toml` and `GatewayConfig`" |
| Migrate | N/A (no DB migrations) | Use for data/script changes only if needed |

---

## 3. Validation Gates Template

```markdown
## Agent Hints:
- **Class:** [builder/reasoner/debugger]
- **Context:** [path to exemplar, e.g. lib/homunculus/gateway/server.rb]
- **Gates:**
  - [ ] P0: No secrets in repo; gateway remains bound to 127.0.0.1; audit log append-only
  - [ ] P1: RSpec passes; coverage ≥75% overall, ≥30% per file
  - [ ] P2: `bin/dev lint` passes (no Metrics/* auto-fix without refactor)
```

---

## 4. Example Story: Health Check Endpoint

**Note:** The gateway already has `plugin :heartbeat, path: "/health"` and `GET api/v1/status` (status, version, uptime). This story treats "health check endpoint" as a single, explicit API route that returns service status and version (e.g. formalize or extend current behaviour).

#### STORY: S-1 Add API health check returning service status and version

- **Description:** As a **operator or orchestrator**, I want **a single HTTP endpoint that returns service status and version** so that **monitoring and load balancers can verify the service is up and which version is running**.
- **Timebox:** 1–2 hours
- **Action Plan:**
  1. Extend `Homunculus::Gateway::Server` in `lib/homunculus/gateway/server.rb` with a route that returns status and version (e.g. ensure `GET api/v1/health` or reuse/alias existing status behaviour).
  2. Return JSON with at least `status`, `version` (from `Homunculus::VERSION`).
  3. Add or extend specs in `spec/gateway/` or `spec/homunculus/gateway/` for the new or updated endpoint.
  4. Run `bin/dev test` and `bin/dev lint`.
- **Acceptance Criteria:**
  - **GIVEN** the gateway is running  
  - **WHEN** I request `GET /api/v1/health` (or the chosen path)  
  - **THEN** the response is 200 with JSON including `status` and `version`.
- **Technical Context:**
  - Pattern: Roda route under `r.on "api/v1"`; use `Homunculus::VERSION` and existing `SERVER_START_TIME` if uptime is included.
  - Files: `lib/homunculus/gateway/server.rb`, `lib/homunculus/version.rb`.
  - Dependencies: existing `plugin :json`, no new gems.
- **Agent Hints:**
  - **Class:** builder
  - **Context:** `lib/homunculus/gateway/server.rb`
  - **Gates:**
    - [ ] P0: Gateway still bound to 127.0.0.1; no secrets in response
    - [ ] P1: RSpec for gateway route; coverage maintained
    - [ ] P2: RuboCop clean

---

## 5. Project-Specific Rules

Every SPECTRA spec for this project must respect:

- **Naming:** Ruby snake_case files; CamelCase classes under `Homunculus::` namespace. Tools under `Homunculus::Tools::*`, agent under `Homunculus::Agent::*`, gateway under `Homunculus::Gateway::*`.
- **Architectural boundaries:**
  - No business logic in gateway beyond routing and small response shaping; delegate to `Homunculus::Agent::Loop` or other lib modules.
  - Tools inherit from `Homunculus::Tools::Base` and are registered in `lib/homunculus/tools/registry.rb`.
  - Config is read-only at runtime; all overrides via env and `config/default.toml`.
- **Tests:** RSpec only; stub HTTP with Webmock; no real network. New code must have specs; 75% overall and 30% per-file coverage enforced. Run `bin/dev test spec/path/to/file_spec.rb` for the changed area.
- **Deployment / security:** Gateway bound to `127.0.0.1` only. Sandbox enabled for tools. Audit log append-only. Do not add secrets to repo or relax MQTT/blocked_topics. See CLAUDE.md "Risk Gates" for full list.

---

## 6. Artifact Storage

Suggested layout for SPECTRA planning artifacts:

```
[project_root]/
├── docs/spectra/           # Plans: .md, .yaml, .state.json
├── docs/spectra/patterns/  # Reusable pattern snippets (optional)
└── spectra-conventions.md  # This file
```

Use `docs/spectra/` so that `docs/` stays the single place for project documentation and SPECTRA artifacts stay out of `workspace/` (which is agent-facing and prompt-loaded).

---

*Generated for humunculus using SPECTRA v4.2.0 adaptation prompt.*
