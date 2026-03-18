# Plan: Model Management — Ollama Availability Fix + CLI/TUI Model Controls

**Date:** 2026-03-17
**Complexity:** 7/12 (Extended reasoning)
**Confidence:** 90% — AUTO_PROCEED
**Type:** BUG_SPEC (Part A) + REQUEST (Parts B-D)

---

## Approach & Rationale

**Selected strategy:** Session state + minimal Loop patch.

- Add `forced_tier` and `routing_enabled` to Session (extends existing `forced_provider` pattern).
- Loop reads session state and passes `tier:` to Router's existing override parameter.
- Router's budget gate fires unconditionally for all cloud tiers — no bypass possible.
- TUI/CLI get `/models`, `/model <tier>`, `/routing on|off` commands following existing patterns.
- Ollama detection bug fixed via model name normalization (`:latest` suffix matching).

**Rejected alternatives:**
- **ModelManager module:** Over-abstracts for 3 session attributes.
- **SessionAwareRouter wrapper:** Adds indirection for marginal elegance.

---

## Story Hierarchy

### FEATURE 1: Fix Ollama Model Availability Detection

#### STORY 1.1: Fix model name matching in fleet list
- **Timebox:** 1d | **Risk:** P2 | **Dependencies:** none
- **Files:** `bin/ollama_list_table.rb`, `bin/ollama`
- **Root cause:** Ollama returns `nomic-embed-text:latest` but fleet config says `nomic-embed-text` (no tag). Exact match fails.
- **Fix:** When looking up installed models, also try `"#{model}:latest"`. In `missing_models()`, same normalization.
- **AC:**
  - GIVEN `nomic-embed-text` installed (reported as `nomic-embed-text:latest`) WHEN `bin/ollama list` THEN shows "Installed"
  - GIVEN `qwen3:14b` installed (exact match) WHEN `bin/ollama list` THEN shows "Installed"

### FEATURE 2: Model Listing Command

#### STORY 2.1: `/models` command in TUI
- **Timebox:** 2d | **Risk:** P2 | **Dependencies:** Story 3.1
- **Files:** `command_registry.rb`, `message_helpers.rb`, `tui.rb`, `tui_spec.rb`
- **Action:** Add `/models` to CommandRegistry, `show_models` overlay method, dispatch case.
- **AC:**
  - GIVEN TUI with models_router WHEN `/models` THEN overlay shows all tiers with status and current selection
  - GIVEN Ollama unreachable WHEN `/models` THEN local tiers show "unavailable"

#### STORY 2.2: `models` command in CLI
- **Timebox:** 1d | **Risk:** P2 | **Dependencies:** Story 3.1
- **Files:** `cli.rb`, `cli_warmup_spec.rb`
- **Action:** Add `when "models"` case, `print_models` method, update help text.
- **AC:**
  - GIVEN CLI session WHEN `models` THEN formatted tier table prints to stdout

### FEATURE 3: Model Switch Command

#### STORY 3.1: Session-level model override state (FOUNDATION)
- **Timebox:** 1d | **Risk:** P1 | **Dependencies:** none
- **Files:** `session.rb`, `session_spec.rb`
- **Action:** Add `attr_accessor :forced_tier` (nil), `attr_accessor :routing_enabled` (true) to Session. Initialize in constructor.
- **AC:**
  - GIVEN new Session WHEN defaults THEN `forced_tier` nil, `routing_enabled` true
  - GIVEN `session.forced_tier = :coder` WHEN accessed THEN returns `:coder`

#### STORY 3.2: Wire session override into Agent Loop
- **Timebox:** 2d | **Risk:** P0 | **Dependencies:** Story 3.1
- **Files:** `loop.rb`, `loop_spec.rb`
- **Action:** In `complete_via_models_router`, check session state:
  - `routing_enabled == false` + `forced_tier` set → pass `tier: session.forced_tier`
  - `routing_enabled == true` + `forced_tier` set → pass tier on first call, then clear
  - Neither → existing behavior (tier: nil)
- **AC:**
  - GIVEN forced_tier=:coder, routing=off WHEN message THEN router.generate(tier: :coder)
  - GIVEN forced_tier=:workhorse, routing=on WHEN first message THEN tier passed, then cleared
  - GIVEN forced_tier=:cloud_standard, routing=off WHEN budget exceeded THEN Router's gate fires (budget never bypassed)

#### STORY 3.3: `/model <tier>` command in TUI + CLI
- **Timebox:** 2d | **Risk:** P1 | **Dependencies:** Stories 3.1, 3.2
- **Files:** `command_registry.rb`, `tui.rb`, `message_helpers.rb`, `cli.rb`, specs
- **Action:** Extend dispatch to pass full input string for argument extraction. Validate tier against `@models_toml_data["tiers"]`. Set `session.forced_tier`.
- **AC:**
  - GIVEN TUI WHEN `/model coder` THEN session.forced_tier=:coder, confirmation shown
  - GIVEN `/model nonexistent` WHEN processing THEN error lists valid tiers
  - GIVEN CLI WHEN `model coder` THEN same behavior

### FEATURE 4: Routing Toggle

#### STORY 4.1: `/routing on|off` command
- **Timebox:** 2d | **Risk:** P1 | **Dependencies:** Stories 3.1, 3.2
- **Files:** `command_registry.rb`, `message_helpers.rb`, `tui.rb`, `cli.rb`, specs
- **Action:** Add `/routing` command. `on` → `session.routing_enabled = true`, `off` → false. No arg → show state. Update status bar.
- **AC:**
  - GIVEN TUI, routing ON WHEN `/routing off` THEN session.routing_enabled=false, status shows "routing: off"
  - GIVEN routing OFF, forced_tier=:coder WHEN message THEN all messages use coder
  - GIVEN `/routing` no arg WHEN processing THEN shows current state

### FEATURE 5: Validation

#### STORY 5.1: Full test suite + lint
- **Timebox:** 1d | **Risk:** P0 | **Dependencies:** all above
- **Action:** `bin/dev test` (0 failures, >= 75% coverage), `bin/dev lint` (no new offenses).

---

## Execution Sequence

```
Parallel:  1.1 (bug fix)  |  3.1 (session state)
                              ↓
Sequential:               3.2 (loop wiring)
                              ↓
Parallel:  2.1 (TUI /models) | 2.2 (CLI models) | 3.3 (/model <tier>) | 4.1 (/routing)
                              ↓
Sequential:               5.1 (full validation)
```

## Architectural Notes

1. **Session owns routing state** — not Router or Loop. Router is stateless shared infrastructure.
2. **Routing ON + forced_tier = first-message override** — tier is cleared after first generate() call.
3. **No Router modifications needed** — existing `tier:` param and budget gate handle everything.
4. **Budget safety invariant** — Router#generate line 58 fires for ALL anthropic-provider tiers. forced_tier to cloud_* is budget-gated automatically.
