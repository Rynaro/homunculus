# Plan: Familiars — Pluggable OS-Level Notification System

**Date:** 2026-03-18
**Complexity:** 9/12 (Extended reasoning — new subsystem, Docker integration, cross-platform, security-sensitive)
**Confidence:** 87% — AUTO_PROCEED
**Type:** REQUEST (new capability)

---

## Naming: Familiars

**Why "Familiars":** In alchemic and Hermetic tradition, a *familiar* is a spirit that attaches itself to a practitioner — dispatched on errands, delivering messages, acting as a semi-autonomous servant. Paracelsus, who originated the homunculus myth, also wrote extensively about familiars. The concept maps precisely: each Familiar is an independent, pluggable notification channel that the Homunculus dispatches outward to reach the user in the physical world.

- Module: `Homunculus::Familiars`
- Config section: `[familiars]`
- Docker profile: `--with-ntfy`
- CLI flag: `familiars status`, `familiars test`

Alternative names considered and rejected:
- **Chimeras** — composite creature metaphor works for plugins, but common usage implies "illusory/impossible"
- **Emanations** — beautiful for the outward-flow concept, but too abstract for individual plugin instances
- **Sylphs** — Paracelsus's air elementals, strong runner-up, but "Familiars" has more immediate semantic clarity
- **Mercuries** — divine messenger fits perfectly, but the plural is awkward in English

---

## Research Summary: Notification Architecture

### Security Analysis

| Approach | Breaks Isolation? | Risk | Verdict |
|----------|------------------|------|---------|
| D-Bus socket mount | **YES** — exposes entire desktop bus | HIGH | **REJECT** — privilege escalation vector |
| X11 socket mount | **YES** — exposes display server | HIGH | **REJECT** |
| Shared volume + host watcher | No | Low | Viable but requires host-side daemon |
| **ntfy.sh sidecar** | **No** | **Low** | **SELECTED** — HTTP-only, zero host sockets |
| gotify sidecar | No | Low | Viable, but weaker mobile story (no iOS) |
| MQTT + host watcher | No | Low | Viable, leverages existing infra |
| apprise-api sidecar | No | Low | Viable as future fan-out layer |

### Why ntfy.sh

1. **Zero host socket mounting** — container sends HTTP POST; user subscribes via PWA/app. No D-Bus, no X11, no host filesystem bridging. Container isolation fully preserved.
2. **Cross-platform via PWA** — ntfy's web UI is an installable PWA with Web Push API support. Works on Linux, macOS, Windows without native dependencies. Android and iOS native apps also available.
3. **Self-hosted, single binary** — Go binary, negligible resources (~10MB RAM). Runs as Docker Compose sidecar on the internal network.
4. **Auth/ACL** — `auth-default-access: deny-all` + per-topic tokens. Prevents unauthorized subscription or publishing.
5. **Already Docker-native** — `binwiederhier/ntfy` image, well-maintained, widely used in homelab community.
6. **MQTT bridge possible** — ntfy can publish to MQTT topics, enabling future unification with existing MQTT infrastructure.

### What we're NOT doing

- **NOT mounting D-Bus** — this is the key security decision. D-Bus mounting would give the container access to the entire desktop session, defeating containerization.
- **NOT requiring host-side daemons** — the user subscribes via browser PWA or mobile app. Zero host installation needed.
- **NOT using `notify-send` from inside containers** — this would require D-Bus access.
- **NOT using `--network=host`** — ntfy runs on the internal Docker network. Only the subscription port is exposed to localhost.

---

## Approach & Rationale

**Selected strategy:** ntfy sidecar + Familiars abstraction layer.

The Familiars subsystem is a thin abstraction over notification channels. Phase 1 ships ntfy as the primary channel. The abstraction supports future channels (apprise, MQTT-to-desktop, email) without rearchitecting.

**Architecture:**

```
Agent Loop / Scheduler / Heartbeat / Tools
          │
          ▼
  Scheduler::Notification (existing — quiet hours, rate limiting, priority)
          │
          ▼ deliver_fn callback
  Familiars::Dispatcher (NEW — routes to enabled channels)
          │
          ├── Familiars::Channels::Ntfy (HTTP POST to ntfy sidecar)
          ├── Familiars::Channels::Log (always-on, writes to SemanticLogger)
          └── (future: Apprise, MQTT, Email, etc.)
```

**Key design decisions:**

1. **Layer on existing Scheduler::Notification** — don't replace it. The existing system handles quiet hours, rate limiting, priority, and queueing. Familiars plugs in as the `deliver_fn` backend, adding *where* notifications go (ntfy, log, etc.) while Scheduler::Notification handles *when* and *how often*.

2. **Switchable at config level** — `[familiars] enabled = false` disables the entire subsystem. Individual channels switchable via `[familiars.ntfy] enabled = true/false`.

3. **ntfy on internal network only** — The ntfy container lives on `homunculus-net` (internal, no external access). The agent container reaches it via `http://ntfy:80`. The subscription port (default 2586) is exposed to `127.0.0.1` only for the user's browser/app to connect.

4. **Auth-hardened by default** — ntfy config ships with `auth-default-access: deny-all`. A pre-generated token is shared between agent container and ntfy via env var (`FAMILIARS_NTFY_TOKEN`). The user gets a read-only token for subscribing.

5. **Graceful degradation** — if ntfy is unreachable, Familiars logs the notification and continues. Never blocks the agent loop.

**Rejected alternatives:**

- **gotify instead of ntfy** — gotify has no official iOS app, weaker PWA story, and more complex setup. ntfy is simpler and better-suited for personal use.
- **apprise as primary** — apprise is a *router*, not a *server*. It can fan out to ntfy/email/Slack but doesn't provide a subscription UI. Better as a future addition layered on top.
- **Direct MQTT-to-desktop** — requires host-side MQTT subscriber daemon (MQTT2NotifySend or similar). Breaks the zero-host-install principle. Could be a future channel for advanced users.
- **Replace Scheduler::Notification entirely** — existing system works well. Replacing it would be a high-risk rewrite for no gain.

---

## Story Hierarchy

### PROJECT: Familiars — Pluggable OS-Level Notification System

### FEATURE 1: Core Familiars Subsystem

#### STORY 1.1: Familiars configuration schema
- **Timebox:** 1d | **Risk:** P1 | **Dependencies:** none
- **As a** system administrator, **I want** Familiars to be configurable via TOML + env vars **so that** I can enable/disable notification channels without code changes.
- **Files:** `config/default.toml`, `lib/homunculus/config.rb`
- **Action:**
  - Add `[familiars]` section to `default.toml` with `enabled = false` (off by default)
  - Add `[familiars.ntfy]` subsection with `enabled`, `url`, `topic`, `publish_token` (env var override)
  - Create `FamiliarsConfig` and `FamiliarsNtfyConfig` Dry::Struct classes in config.rb
  - Add env var overrides: `FAMILIARS_ENABLED`, `FAMILIARS_NTFY_URL`, `FAMILIARS_NTFY_TOPIC`, `FAMILIARS_NTFY_TOKEN`
- **AC:**
  - GIVEN default config WHEN loaded THEN `config.familiars.enabled` is `false`
  - GIVEN `FAMILIARS_ENABLED=true` env var WHEN config loaded THEN `config.familiars.enabled` is `true`
  - GIVEN `[familiars.ntfy]` section WHEN parsed THEN returns `FamiliarsNtfyConfig` with all fields
- **Agent Hints:** Builder agent, context files: `config/default.toml`, `lib/homunculus/config.rb`

#### STORY 1.2: Channel base class and registry
- **Timebox:** 1d | **Risk:** P1 | **Dependencies:** 1.1
- **As a** developer, **I want** a channel abstraction **so that** new notification channels can be added without modifying the dispatcher.
- **Files:** `lib/homunculus/familiars/channel.rb`, `lib/homunculus/familiars/registry.rb`
- **Action:**
  - Create `Familiars::Channel` base class with `#deliver(title:, message:, priority:)` interface
  - Channel has `#name`, `#enabled?`, `#healthy?` methods
  - Create `Familiars::Registry` to hold configured channels, supports `#each_enabled`, `#get(name)`
  - Include `SemanticLogger::Loggable` in base
- **AC:**
  - GIVEN a Channel subclass WHEN `deliver` not implemented THEN raises `NotImplementedError`
  - GIVEN registry with 2 channels (1 enabled, 1 disabled) WHEN `each_enabled` THEN yields only enabled one
  - GIVEN registry WHEN `get(:ntfy)` THEN returns the ntfy channel instance
- **Agent Hints:** Builder agent, follow pattern from `lib/homunculus/tools/base.rb` + `tools/registry.rb`

#### STORY 1.3: Dispatcher — fan-out to enabled channels
- **Timebox:** 2d | **Risk:** P0 | **Dependencies:** 1.1, 1.2
- **As the** notification subsystem, **I want** a dispatcher that fans out to all enabled channels **so that** a single `notify()` call reaches all configured outputs.
- **Files:** `lib/homunculus/familiars/dispatcher.rb`
- **Action:**
  - Create `Familiars::Dispatcher` that holds a `Registry` and dispatches to all enabled channels
  - `#notify(title:, message:, priority:)` iterates `registry.each_enabled` and calls `deliver`
  - Each channel delivery wrapped in `rescue StandardError` — one channel failure doesn't block others
  - Returns hash of `{ channel_name: :delivered | :failed }`
  - Thread-safe (Mutex around delivery tracking)
  - `#status` returns health of all channels
- **AC:**
  - GIVEN 2 enabled channels WHEN `notify` THEN both receive the message
  - GIVEN 1 channel raises error WHEN `notify` THEN other channel still delivers, error logged
  - GIVEN dispatcher WHEN `status` THEN returns `{ ntfy: { enabled: true, healthy: true }, log: { enabled: true, healthy: true } }`
- **Agent Hints:** Builder agent, context: `lib/homunculus/scheduler/notification.rb` for pattern reference

#### STORY 1.4: Log channel (always-on fallback)
- **Timebox:** ≤1d | **Risk:** P2 | **Dependencies:** 1.2
- **As a** system operator, **I want** all notifications logged regardless of channel config **so that** I have an audit trail of dispatched notifications.
- **Files:** `lib/homunculus/familiars/channels/log.rb`
- **Action:**
  - Create `Familiars::Channels::Log < Channel` — always enabled, writes to SemanticLogger
  - Logs title, message, priority, timestamp
  - `healthy?` always returns `true`
- **AC:**
  - GIVEN log channel WHEN `deliver` THEN SemanticLogger entry written with title + priority
  - GIVEN log channel WHEN `enabled?` THEN always `true`
- **Agent Hints:** Builder agent, trivial implementation

---

### FEATURE 2: ntfy Channel Integration

#### STORY 2.1: ntfy channel implementation
- **Timebox:** 2d | **Risk:** P0 | **Dependencies:** 1.1, 1.2
- **As the** Familiars subsystem, **I want** an ntfy channel **so that** notifications are delivered via HTTP POST to the ntfy sidecar.
- **Files:** `lib/homunculus/familiars/channels/ntfy.rb`
- **Action:**
  - Create `Familiars::Channels::Ntfy < Channel`
  - Uses HTTPX (already a dependency) to POST to ntfy URL
  - Maps priority levels: `:low` → ntfy 2, `:normal` → ntfy 3, `:high` → ntfy 5
  - Sets `Authorization: Bearer <token>` header from config
  - Sends JSON payload: `{ "topic": ..., "title": ..., "message": ..., "priority": N }`
  - `healthy?` does a lightweight HEAD request to ntfy base URL (cached for 60s)
  - Timeout: 5 seconds per request, never blocks agent loop
  - Graceful failure: log and return `:failed` on any HTTP error
- **AC:**
  - GIVEN ntfy reachable WHEN `deliver(title: "Test", message: "Hello", priority: :normal)` THEN HTTP POST sent with correct JSON payload
  - GIVEN ntfy unreachable WHEN `deliver` THEN returns `:failed`, error logged, no exception raised
  - GIVEN `:high` priority WHEN `deliver` THEN ntfy priority field is 5
  - GIVEN ntfy token configured WHEN `deliver` THEN `Authorization: Bearer <token>` header present
- **Agent Hints:** Builder agent, context: `lib/homunculus/agent/models/anthropic_client.rb` for HTTPX usage pattern

#### STORY 2.2: ntfy Docker Compose service
- **Timebox:** 1d | **Risk:** P1 | **Dependencies:** none
- **As a** user, **I want** ntfy to run as an optional Docker Compose service **so that** I can enable it with `--with-ntfy`.
- **Files:** `docker-compose.yml`, `config/ntfy/server.yml`, `bin/assistant`
- **Action:**
  - Add `ntfy` service to `docker-compose.yml` with `profiles: [ntfy]`
  - Image: `binwiederhier/ntfy`, command: `serve`
  - Networks: `homunculus-net` (internal) + new `ntfy-egress` (for PWA web push delivery)
  - Expose port: `127.0.0.1:2586:80` (for user's browser to subscribe)
  - Volume: `./config/ntfy:/etc/ntfy:ro` for server config
  - Volume: `ntfy-cache:/var/cache/ntfy` for message persistence
  - Security: `no-new-privileges:true`
  - Create `config/ntfy/server.yml` with:
    - `auth-default-access: deny-all`
    - `base-url: http://localhost:2586`
    - `behind-proxy: false`
    - `cache-file: /var/cache/ntfy/cache.db`
  - Update `bin/assistant`:
    - Add `--with-ntfy` to `parse_profile_flags`
    - Add ntfy to `bin/assistant doctor` diagnostics
    - Add ntfy to `bin/assistant setup` (token generation guidance)
- **AC:**
  - GIVEN `bin/assistant up --with-ntfy` WHEN executed THEN ntfy container starts on internal network
  - GIVEN ntfy running WHEN agent container POSTs to `http://ntfy:80/homunculus` THEN message delivered
  - GIVEN ntfy running WHEN user opens `http://localhost:2586/homunculus` in browser THEN subscription page shown
  - GIVEN ntfy config WHEN loaded THEN `auth-default-access` is `deny-all`
- **Agent Hints:** Builder agent, context: `docker-compose.yml`, `bin/assistant`

#### STORY 2.3: ntfy token management in setup
- **Timebox:** 1d | **Risk:** P1 | **Dependencies:** 2.2
- **As a** user, **I want** `bin/assistant setup` to generate ntfy auth tokens **so that** the notification channel is secure by default.
- **Files:** `bin/assistant`
- **Action:**
  - During `bin/assistant setup`, if user enables ntfy:
    - Generate a random publish token (agent → ntfy, read-write on `homunculus` topic)
    - Generate a random subscribe token (user → ntfy, read-only on `homunculus` topic)
    - Add `FAMILIARS_NTFY_TOKEN=<publish_token>` to `.env`
    - Print subscribe instructions: "Open http://localhost:2586, add topic 'homunculus', use token: <subscribe_token>"
  - Token creation uses `ntfy user add` and `ntfy access` via `docker exec`
  - Provide `bin/assistant familiars setup` subcommand for post-install token configuration
- **AC:**
  - GIVEN `bin/assistant setup` with ntfy enabled WHEN tokens generated THEN `.env` contains `FAMILIARS_NTFY_TOKEN`
  - GIVEN publish token WHEN agent POSTs THEN message published
  - GIVEN subscribe token WHEN user subscribes THEN messages received
  - GIVEN no token WHEN unauthorized POST THEN ntfy returns 401
- **Agent Hints:** Builder agent, context: `bin/assistant` setup section

---

### FEATURE 3: Wire Familiars into Existing Notification Pipeline

#### STORY 3.1: Initialize Familiars in interfaces
- **Timebox:** 2d | **Risk:** P0 | **Dependencies:** 1.1, 1.2, 1.3, 1.4, 2.1
- **As the** system, **I want** Familiars initialized in all interfaces **so that** notifications flow to OS-level channels.
- **Files:** `lib/homunculus/interfaces/cli.rb`, `lib/homunculus/interfaces/tui.rb`, `lib/homunculus/interfaces/telegram.rb`
- **Action:**
  - In each interface's `setup_components!` or equivalent:
    - Build `Familiars::Dispatcher` from config (if `config.familiars.enabled`)
    - Register channels: Log (always), Ntfy (if enabled + URL configured)
  - Wire the existing `Scheduler::Notification#deliver_fn` to route through BOTH:
    - The existing interface-specific delivery (CLI stdout, Telegram message, TUI panel)
    - AND `Familiars::Dispatcher#notify` for OS-level delivery
  - This is additive: existing in-interface notifications continue unchanged. Familiars adds a parallel delivery path.
  - Extract a shared `build_familiars_dispatcher` helper into a module (e.g., `Interfaces::FamiliarsSetup`)
- **AC:**
  - GIVEN Familiars enabled + CLI WHEN scheduler notification fires THEN both CLI stdout AND ntfy receive the message
  - GIVEN Familiars enabled + Telegram WHEN scheduler notification fires THEN both Telegram message AND ntfy receive the message
  - GIVEN Familiars disabled WHEN scheduler notification fires THEN only interface-specific delivery (existing behavior unchanged)
  - GIVEN ntfy unreachable WHEN notification fires THEN interface-specific delivery still succeeds, ntfy failure logged
- **Agent Hints:** Builder agent, context: all three interface files (look for `build_notification_service` / `deliver_fn` wiring)

#### STORY 3.2: Agent-triggered notifications (tool results, session events)
- **Timebox:** 2d | **Risk:** P1 | **Dependencies:** 3.1
- **As a** user running the agent in the background, **I want** important agent events to trigger OS notifications **so that** I'm alerted without watching the terminal.
- **Files:** `lib/homunculus/familiars/dispatcher.rb`, `lib/homunculus/agent/loop.rb`
- **Action:**
  - Define notification-worthy events:
    - Session complete (agent finished processing)
    - Tool requiring confirmation (agent is waiting for user approval)
    - Error/failure in agent loop (unrecoverable error)
    - Scheduled job result (already handled via Scheduler::Notification)
  - Add `Familiars::Dispatcher` reference to Agent Loop (passed at initialization)
  - Agent loop calls `dispatcher.notify(...)` at event boundaries
  - Each event has a sensible default priority: session complete → `:normal`, confirmation needed → `:high`, error → `:high`
  - Configurable: `[familiars] notify_on = ["session_complete", "confirmation_needed", "error"]`
- **AC:**
  - GIVEN agent completes session WHEN Familiars enabled THEN "Session complete" notification sent
  - GIVEN tool needs confirmation WHEN agent waiting THEN "Confirmation needed: <tool>" notification sent as `:high`
  - GIVEN `notify_on` excludes `session_complete` WHEN session completes THEN no notification sent for that event
- **Agent Hints:** Reasoner agent, context: `lib/homunculus/agent/loop.rb`, `lib/homunculus/familiars/dispatcher.rb`

---

### FEATURE 4: User-Facing Status & Control

#### STORY 4.1: `familiars` CLI/TUI command
- **Timebox:** 1d | **Risk:** P2 | **Dependencies:** 3.1
- **As a** user, **I want** to check Familiars status and send test notifications from CLI/TUI **so that** I can verify my notification setup works.
- **Files:** `lib/homunculus/interfaces/cli.rb`, `lib/homunculus/interfaces/tui.rb`
- **Action:**
  - Add `familiars` / `/familiars` command:
    - `familiars status` — show enabled channels, health, delivery stats
    - `familiars test` — send a test notification to all enabled channels
  - Follow existing command patterns (`scheduler status`, `/models`)
- **AC:**
  - GIVEN Familiars enabled with ntfy WHEN `familiars status` THEN shows: `ntfy: enabled, healthy, 3 deliveries last hour`
  - GIVEN Familiars enabled WHEN `familiars test` THEN test notification delivered to all channels
  - GIVEN Familiars disabled WHEN `familiars status` THEN shows "Familiars: disabled"
- **Agent Hints:** Builder agent, context: CLI/TUI command dispatch patterns

#### STORY 4.2: `send_notification` tool (agent-callable)
- **Timebox:** 2d | **Risk:** P1 | **Dependencies:** 1.3, 3.1
- **As the** agent, **I want** a `send_notification` tool **so that** I can proactively alert the user during autonomous operation.
- **Files:** `lib/homunculus/tools/send_notification.rb`, `lib/homunculus/tools/registry.rb`, `config/default.toml`
- **Action:**
  - Create `Tools::SendNotification < Base` — elevated tool (requires user confirmation)
  - Parameters: `title` (string, required), `message` (string, required), `priority` (string, optional, default "normal")
  - Delegates to `Familiars::Dispatcher#notify`
  - Add to `security.require_confirmation` in default.toml
  - Register in interfaces when Familiars is enabled
  - Trust level: `:mixed` (agent-generated content sent to external system)
- **AC:**
  - GIVEN agent calls `send_notification(title: "Reminder", message: "Time to drink water!")` WHEN approved THEN notification delivered via Familiars
  - GIVEN tool called WHEN user denies confirmation THEN notification not sent
  - GIVEN Familiars disabled WHEN tool called THEN returns error "Familiars not enabled"
- **Agent Hints:** Builder agent, context: `lib/homunculus/tools/base.rb`, any existing tool for pattern

---

### FEATURE 5: Testing & Documentation

#### STORY 5.1: Comprehensive specs for Familiars subsystem
- **Timebox:** 2d | **Risk:** P1 | **Dependencies:** 1.1–1.4, 2.1, 3.1–3.2, 4.1–4.2
- **As a** developer, **I want** full test coverage for Familiars **so that** the subsystem meets the 75%/30% coverage gates.
- **Files:** `spec/familiars/`, `spec/tools/send_notification_spec.rb`
- **Action:**
  - `spec/familiars/channel_spec.rb` — base class contract
  - `spec/familiars/registry_spec.rb` — registration, filtering
  - `spec/familiars/dispatcher_spec.rb` — fan-out, error isolation, status
  - `spec/familiars/channels/log_spec.rb` — logging behavior
  - `spec/familiars/channels/ntfy_spec.rb` — HTTP stubbing (WebMock), auth headers, priority mapping, timeout, graceful failure
  - `spec/tools/send_notification_spec.rb` — tool interface, confirmation requirement
  - `spec/config_spec.rb` — extend existing config specs for FamiliarsConfig
  - All HTTP calls stubbed via WebMock (no real ntfy in tests)
- **AC:**
  - GIVEN full test suite WHEN `bin/dev test` THEN all Familiars specs pass
  - GIVEN SimpleCov WHEN report generated THEN Familiars files ≥30% per-file coverage
  - GIVEN ntfy specs WHEN run THEN no real HTTP calls made (WebMock enforced)
- **Agent Hints:** Builder agent, follow existing spec patterns in `spec/scheduler/`, `spec/tools/`

#### STORY 5.2: Update CLAUDE.md and config documentation
- **Timebox:** ≤1d | **Risk:** P2 | **Dependencies:** all above
- **As a** developer (or Claude Code), **I want** CLAUDE.md updated **so that** future sessions understand the Familiars subsystem.
- **Files:** `CLAUDE.md`, `config/default.toml` (inline comments)
- **Action:**
  - Update Architecture section: add Familiars to the flow diagram
  - Update tool count (currently 19 → 20 with send_notification)
  - Add Familiars to Key Modules section
  - Add `bin/assistant` command examples for `--with-ntfy`
  - Add Risk Gate: ntfy credentials in `.env` only, never commit tokens
- **AC:**
  - GIVEN CLAUDE.md WHEN read THEN Familiars architecture documented
  - GIVEN CLAUDE.md WHEN read THEN tool count reflects send_notification addition
- **Agent Hints:** Builder agent

---

## Execution Sequence

```
Phase 1 — Foundation (Stories 1.1, 1.2, 1.4)     [3d, parallelizable]
  ├── 1.1: Config schema
  ├── 1.2: Channel base + registry
  └── 1.4: Log channel

Phase 2 — Core + ntfy (Stories 1.3, 2.1, 2.2)    [3d, 1.3 depends on Phase 1]
  ├── 1.3: Dispatcher
  ├── 2.1: ntfy channel (depends on 1.2)
  └── 2.2: Docker Compose service (independent)

Phase 3 — Integration (Stories 2.3, 3.1, 3.2)    [3d]
  ├── 2.3: Token management (depends on 2.2)
  ├── 3.1: Wire into interfaces (depends on Phase 2)
  └── 3.2: Agent-triggered events (depends on 3.1)

Phase 4 — UX + Quality (Stories 4.1, 4.2, 5.1, 5.2)  [3d]
  ├── 4.1: CLI/TUI commands (depends on 3.1)
  ├── 4.2: send_notification tool (depends on 1.3)
  ├── 5.1: Specs (depends on all implementation)
  └── 5.2: Documentation (last)
```

**Critical path:** 1.1 → 1.2 → 1.3 → 2.1 → 3.1 → 3.2

---

## Confidence Report

| Factor | Score | Notes |
|--------|-------|-------|
| Pattern match | 90% | Follows established profile/config/interface patterns exactly |
| Requirement clarity | 85% | Clear goal; ntfy selection backed by research; event list may need user refinement |
| Decomposition stability | 88% | Stories are independent, boundaries clean, 3 alternative decompositions converge |
| Constraint compliance | 85% | No isolation breach, auth-hardened, switchable, all risk gates respected |
| **Overall** | **87%** | AUTO_PROCEED |

---

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| ntfy PWA doesn't support Web Push on all browsers | User can't receive background notifications | Document browser compatibility; native apps as fallback |
| ntfy auth token management is manual | UX friction on first setup | `bin/assistant setup` automates token generation |
| Notification spam if agent is too chatty | User disables Familiars entirely | Rate limiting in Scheduler::Notification (existing), `notify_on` filter in config |
| ntfy image breaks or gets compromised | Supply chain risk | Pin to specific ntfy version tag, not `:latest` |
| User expects native `notify-send` integration | Mismatched expectations | Document clearly that PWA/app is the delivery mechanism, explain why D-Bus mounting is unsafe |

---

## File Impact Summary

### New files
- `lib/homunculus/familiars/channel.rb`
- `lib/homunculus/familiars/registry.rb`
- `lib/homunculus/familiars/dispatcher.rb`
- `lib/homunculus/familiars/channels/log.rb`
- `lib/homunculus/familiars/channels/ntfy.rb`
- `lib/homunculus/tools/send_notification.rb`
- `config/ntfy/server.yml`
- `spec/familiars/` (5 spec files)
- `spec/tools/send_notification_spec.rb`

### Modified files
- `config/default.toml` — add `[familiars]` section
- `lib/homunculus/config.rb` — add `FamiliarsConfig`, `FamiliarsNtfyConfig`
- `docker-compose.yml` — add ntfy service + network
- `bin/assistant` — add `--with-ntfy` profile, setup steps, doctor checks
- `lib/homunculus/interfaces/cli.rb` — Familiars init + commands
- `lib/homunculus/interfaces/tui.rb` — Familiars init + commands
- `lib/homunculus/interfaces/telegram.rb` — Familiars init
- `lib/homunculus/agent/loop.rb` — event notifications (minimal touch)
- `lib/homunculus/tools/registry.rb` — register send_notification
- `CLAUDE.md` — architecture, tool count, risk gates
