# Assistant Warm-up: First-Message Latency Mitigation

## Context

When running the Homunculus assistant (CLI, TUI, or Telegram), the **first user message** takes a disproportionately long time (10–60+ seconds) compared to subsequent messages. Root causes:

1. **Ollama model loading** — First POST to `/api/chat` triggers loading a 14B model into RAM/VRAM. Dominant cost.
2. **Embedding model loading** — First call to `/api/embeddings` loads `nomic-embed-text`. Secondary cost.
3. **Prompt building overhead** — First `prompt_builder.build()` reads workspace files (SOUL.md, AGENTS.md, USER.md, MEMORY.md) and runs memory search. Moderate.
4. **Memory index rebuild** — Already handled synchronously in `build_memory_store` during `setup_components!`, but compounds total boot time.

---

## SPECTRA Summary

- **Intent:** CHANGE — Modify existing interface boot sequences and add a warm-up subsystem.
- **Complexity:** 8/12 — Extended (2x reasoning). Multi-component change with concurrency, cross-interface integration, and UX feedback requirements.
- **Pattern:** GENERATE — No existing warm-up template in the codebase. HealthMonitor and ActivityIndicator used as reference patterns.
- **Approach:** Centralized `Warmup` class + Ollama preload technique. A single module runs warm-up steps in a background thread, reporting progress via interface-specific callbacks. Each interface (CLI, TUI, Telegram) integrates by calling `warmup.start!` after `setup_components!` with a display callback.

### Rejected Alternatives

| Alternative | Why Rejected |
|---|---|
| Per-interface inline warm-up | Code duplication across 3 interfaces. Harder to test. Maintenance burden for new steps. |
| HealthMonitor integration | Mixes monitoring (read-only observation) with warming (active preloading). Violates single-responsibility. |
| Event-driven observable pipeline | Over-engineered for 3–4 sequential steps. Ollama loads models serially anyway, so parallelism benefit is marginal. |
| Ollama-only preload (no Ruby module) | No UX feedback, no configurability, no graceful degradation across interfaces. |

---

## Design

### Architecture

```
setup_components!           ← existing (builds providers, memory, tools, loop)
    │
    ▼
Warmup.new(...)             ← NEW: receives ollama_provider, embedder, config, workspace_path
    │
    ├─ start!(callback:)    ← spawns Thread, reports progress via callback
    │   ├─ Step 1: Preload chat model (POST /api/chat, minimal prompt)
    │   ├─ Step 2: Preload embedding model (POST /api/embeddings, "warmup")
    │   └─ Step 3: Pre-read workspace files (SOUL.md, AGENTS.md, USER.md, MEMORY.md)
    │
    ├─ ready?               ← true when all steps complete (or failed gracefully)
    └─ elapsed_ms           ← total warm-up time for logging
    │
    ▼
Interface input loop        ← user can type immediately; warm-up runs in parallel
```

### Warm-up Steps (Ordered by Impact)

| # | Step | What | Estimated Duration | Failure Mode |
|---|---|---|---|---|
| 1 | `preload_chat_model` | POST `/api/chat` with `{ model: "qwen2.5:14b", messages: [{ role: "user", content: "hi" }], stream: false, options: { num_predict: 1 } }` — forces model into RAM/VRAM, generates 1 token | 10–60s (cold) / <1s (warm) | Log warning, continue |
| 2 | `preload_embedding_model` | Call `embedder.embed("warmup")` — forces embedding model into RAM | 5–15s (cold) / <1s (warm) | Log warning, continue |
| 3 | `preread_workspace_files` | Read SOUL.md, AGENTS.md, USER.md, MEMORY.md into Ruby strings — warms filesystem cache and validates presence | <1s | Log warning, continue |

Steps are **sequential** because:
- Ollama loads one model at a time. Starting embedding model load while chat model is still loading would queue and not save time.
- Sequential ordering gives accurate per-step progress feedback.
- Step 3 is nearly instant and runs last for completeness.

### Configuration

```toml
# config/default.toml — new section
[agent.warmup]
enabled = true
preload_chat_model = true
preload_embedding_model = true
preread_workspace_files = true
```

### Interface Integration

| Interface | Warm-up Trigger | UX Feedback | Notes |
|---|---|---|---|
| **CLI** | After `print_banner`, before `loop_input` | Print status lines: `⏳ Warming up... loading model`, `✓ Model loaded (12.3s)`, etc. | User sees "You: " prompt immediately; warm-up lines print above |
| **TUI** | After `initial_render`, before `input_loop` processes first user message | Use `ActivityIndicator` with progress labels in status bar. Push `:info` messages to chat for completed steps | Input loop starts immediately; warm-up progress is visual |
| **Telegram** | After `setup_components!`, before `@bot.listen` | Log-only. No user-facing message (bot should appear instantly ready). | Blocks `listen` briefly — acceptable since Telegram is long-running and users don't notice bot startup |

### Key Design Decisions

1. **Non-blocking for user:** The warm-up thread runs in the background. If the user sends a message before warm-up completes, the message proceeds normally — it just hits the cold Ollama path (same as current behavior). No worse than today, potentially better if some steps already completed.

2. **Graceful degradation:** Every warm-up step is wrapped in `rescue StandardError`. Failures are logged but never crash the interface. The `ready?` flag includes a `@failed_steps` set for observability.

3. **Idempotent:** If the model is already loaded (warm Ollama), the preload completes in <1s. No wasted effort.

4. **Configurable granularity:** Each warm-up step can be individually enabled/disabled via config.

5. **Minimal Ollama overhead:** Chat preload uses `num_predict: 1` to generate only a single token. This forces model loading with minimal compute waste.

---

## Stories (Execution Order)

### Story 1: Warmup Core Module

**As a** developer, **I want** a centralized warm-up module that preloads Ollama models and workspace files **so that** all interfaces can share the same warm-up logic without duplication.

- **Timebox:** 2d
- **Risk:** P0 — Foundation for all subsequent stories.

**Action Plan:**

1. **Create** `lib/homunculus/agent/warmup.rb`:
   - Class `Homunculus::Agent::Warmup`
   - Constructor takes: `ollama_provider:` (OllamaProvider or nil), `embedder:` (Memory::Embedder or nil), `config:` (Homunculus::Config), `workspace_path:` (String)
   - `start!(callback: nil)` — spawns `@thread = Thread.new { run_steps(callback) }`
   - `ready?` — returns `@done` (AtomicBoolean or simple instance var protected by mutex)
   - `elapsed_ms` — monotonic clock delta from start to finish
   - `results` — hash of `{ step_name: { status: :ok/:skipped/:failed, elapsed_ms:, error: } }`
   - Private `run_steps(callback)` — iterates steps, calls `callback&.call(event, step_name, detail)` where event is `:start`, `:complete`, `:skip`, `:fail`
2. **Implement** `preload_chat_model` step:
   - Skip if `ollama_provider` is nil or config `agent.warmup.preload_chat_model` is false
   - Resolve model name from config (`config.models[:local].default_model`)
   - Call `ollama_provider.generate(messages: [{ role: "user", content: "hi" }], model: model_name, max_tokens: 1, temperature: 0)` — minimal generation forces model load
   - Rescue any error, log warning, mark step as failed
3. **Implement** `preload_embedding_model` step:
   - Skip if `embedder` is nil or config `agent.warmup.preload_embedding_model` is false
   - Call `embedder.embed("warmup")` — forces embedding model load
   - Rescue any error, log warning, mark step as failed
4. **Implement** `preread_workspace_files` step:
   - Skip if config `agent.warmup.preread_workspace_files` is false
   - Read SOUL.md, AGENTS.md, USER.md, MEMORY.md from workspace_path
   - Store results in an instance variable (optional: can be queried by prompt builder)
   - Rescue any error, log warning, mark step as failed
5. **Test** spec at `spec/agent/warmup_spec.rb`:
   - Test each step independently with mocked Ollama/embedder
   - Test that failures in one step don't prevent subsequent steps
   - Test `ready?` transitions from false to true
   - Test callback receives correct events
   - Test config disabling individual steps
   - Test that `start!` is non-blocking (returns immediately)

**Acceptance Criteria:**

- GIVEN warm-up is enabled and Ollama is available, WHEN `start!` is called, THEN the chat model is preloaded via a minimal generation request and `ready?` returns true after completion.
- GIVEN warm-up is enabled but Ollama is unreachable, WHEN `start!` is called, THEN the step fails gracefully with a logged warning and `ready?` still becomes true (with the step marked as failed).
- GIVEN `preload_chat_model` is disabled in config, WHEN `start!` is called, THEN the chat model step is skipped.
- GIVEN a callback is provided, WHEN each step starts and completes, THEN the callback receives `:start` and `:complete` (or `:fail`) events with the step name.

**Technical Context:**

- Pattern: Follow `HealthMonitor` for provider interaction style
- Files: `lib/homunculus/agent/warmup.rb` (new), `lib/homunculus/config.rb` (extend struct), `config/default.toml` (add section)
- Dependencies: `OllamaProvider`, `Memory::Embedder`, `Homunculus::Config`

**Agent Hints:**

- Agent class: Builder (speed-class)
- Context files: `lib/homunculus/agent/models/ollama_provider.rb`, `lib/homunculus/memory/embedder.rb`, `lib/homunculus/agent/models/health_monitor.rb`, `lib/homunculus/config.rb`
- Validation: `bin/dev test spec/agent/warmup_spec.rb && bin/dev lint`

---

### Story 2: Configuration Schema Extension

**As a** user, **I want** to configure which warm-up steps are enabled **so that** I can skip unnecessary preloading (e.g., on fast hardware or when embeddings are disabled).

- **Timebox:** 0.5d
- **Risk:** P1 — Config must be in place before interface integration.

**Action Plan:**

1. **Extend** `config/default.toml` with `[agent.warmup]` section (see Design above).
2. **Extend** `lib/homunculus/config.rb` — add `Warmup` Dry::Struct with boolean fields `enabled`, `preload_chat_model`, `preload_embedding_model`, `preread_workspace_files` (all default `true`).
3. **Wire** the new struct into the `Agent` config section.
4. **Test** config parsing in existing config specs — add warmup defaults and override tests.

**Acceptance Criteria:**

- GIVEN no warmup config in TOML, WHEN config is loaded, THEN warmup defaults to enabled with all steps true.
- GIVEN `agent.warmup.enabled = false`, WHEN config is loaded, THEN `config.agent.warmup.enabled` returns false.
- GIVEN `agent.warmup.preload_chat_model = false`, WHEN warm-up runs, THEN the chat model step is skipped.

**Technical Context:**

- Pattern: Follow existing `[agent.context]` config pattern
- Files: `config/default.toml`, `lib/homunculus/config.rb`, `spec/config_spec.rb`
- Dependencies: Story 1 (consumed by Warmup module)

**Agent Hints:**

- Agent class: Builder (speed-class)
- Context files: `lib/homunculus/config.rb`, `config/default.toml`
- Validation: `bin/dev test spec/config_spec.rb && bin/dev lint`

---

### Story 3: CLI Warm-up Integration

**As a** CLI user, **I want** to see warm-up progress after the banner prints **so that** I know the assistant is preparing and will be fast when I type my first message.

- **Timebox:** 1d
- **Risk:** P1 — Most common interactive interface.

**Action Plan:**

1. **Modify** `CLI#start` — after `print_banner`, create and start `Warmup` instance with a CLI-specific callback:
   ```ruby
   warmup = Agent::Warmup.new(
     ollama_provider: @ollama_provider,
     embedder: @memory_store&.embedder,
     config: @config,
     workspace_path: @config.agent.workspace_path
   )
   warmup.start!(callback: method(:warmup_status))
   ```
2. **Implement** `CLI#warmup_status(event, step, detail)`:
   - `:start` → `puts "⏳ #{human_step_name(step)}..."`
   - `:complete` → `puts "✓ #{human_step_name(step)} (#{detail[:elapsed_ms]}ms)"`
   - `:skip` → `puts "⊘ #{human_step_name(step)} (skipped)"`
   - `:fail` → `puts "✗ #{human_step_name(step)} failed: #{detail[:error]}"`
   - `:done` → `puts "Ready! (total: #{detail[:elapsed_ms]}ms)\n" + "-" * 60`
3. **Ensure** the prompt prints "You: " immediately after banner — warm-up lines appear between banner and first prompt.
4. **Test** integration: mock warmup, verify status lines are printed to stdout.

**Acceptance Criteria:**

- GIVEN CLI starts with warmup enabled, WHEN the banner is printed, THEN warm-up status lines appear showing each step's progress and the "You: " prompt appears immediately (warm-up runs in background thread).
- GIVEN CLI starts with warmup disabled, WHEN the banner is printed, THEN no warm-up lines appear and behavior is identical to current.
- GIVEN a user types a message before warm-up completes, WHEN the message is sent, THEN it processes normally (potentially slower for model load, same as current).

**Technical Context:**

- Pattern: Follow existing `print_banner` → `loop_input` flow
- Files: `lib/homunculus/interfaces/cli.rb`
- Dependencies: Stories 1, 2

**Agent Hints:**

- Agent class: Builder (speed-class)
- Context files: `lib/homunculus/interfaces/cli.rb`, `lib/homunculus/agent/warmup.rb`
- Validation: `bin/dev test spec/interfaces/cli_spec.rb && bin/dev lint`

---

### Story 4: TUI Warm-up Integration

**As a** TUI user, **I want** to see warm-up progress in the status bar and as info messages **so that** I know the system is preparing without disrupting the visual interface.

- **Timebox:** 1d
- **Risk:** P1 — TUI is the richest interface and needs the most polished feedback.

**Action Plan:**

1. **Modify** `TUI#start` — after `initial_render`, create and start `Warmup` with TUI-specific callback:
   ```ruby
   warmup = Agent::Warmup.new(
     ollama_provider: @ollama_provider,
     embedder: @memory_store&.embedder,
     config: @config,
     workspace_path: @config.agent.workspace_path
   )
   warmup.start!(callback: method(:warmup_status))
   ```
2. **Implement** `TUI#warmup_status(event, step, detail)`:
   - `:start` → `@activity_indicator.start("Loading #{human_step_name(step)}...")`
   - `:complete` → `push_info_message("✓ #{human_step_name(step)} (#{detail[:elapsed_ms]}ms)")` then `refresh_all`
   - `:fail` → `push_info_message("⚠ #{human_step_name(step)} unavailable")` then `refresh_all`
   - `:done` → `@activity_indicator.stop` then `push_info_message("Ready in #{detail[:elapsed_ms]}ms")` then `refresh_all`
3. **Ensure** the input loop starts immediately — warm-up runs concurrently. Use mutex protection on shared state (the callback pushes messages via `@messages_mutex`).
4. **Update** warm greeting to mention warm-up if it's still running: check `warmup.ready?` and optionally append "Warming up models..." to the greeting info line.

**Acceptance Criteria:**

- GIVEN TUI starts with warmup enabled, WHEN the screen renders, THEN the activity indicator shows warm-up progress and info messages appear in the chat panel as steps complete.
- GIVEN warm-up completes, THEN the activity indicator stops and a "Ready" info message appears.
- GIVEN a user types during warm-up, WHEN they send a message, THEN it processes normally while warm-up continues in the background.

**Technical Context:**

- Pattern: Follow existing `ActivityIndicator` usage in `handle_message`
- Files: `lib/homunculus/interfaces/tui.rb`
- Dependencies: Stories 1, 2
- Concurrency: Callback runs on warmup thread; must use `@messages_mutex` for thread-safe message pushing

**Agent Hints:**

- Agent class: Builder (speed-class)
- Context files: `lib/homunculus/interfaces/tui.rb`, `lib/homunculus/interfaces/tui/activity_indicator.rb`
- Validation: `bin/dev test spec/interfaces/tui_spec.rb && bin/dev lint`

---

### Story 5: Telegram Warm-up Integration

**As a** Telegram bot operator, **I want** the bot to preload models on startup **so that** the first user message is fast without any visible delay.

- **Timebox:** 0.5d
- **Risk:** P2 — Telegram is long-running; startup latency matters less than CLI/TUI.

**Action Plan:**

1. **Modify** `Telegram#start` — before `@bot.listen`, run warm-up with log-only callback:
   ```ruby
   warmup = Agent::Warmup.new(
     ollama_provider: @providers[:ollama]&.respond_to?(:generate) ? build_ollama_for_warmup : nil,
     embedder: @memory_store&.embedder,
     config: @config,
     workspace_path: @config.agent.workspace_path
   )
   warmup.start!(callback: method(:warmup_log))
   warmup.wait! # Block until warm-up completes before accepting messages
   ```
2. **Implement** `Telegram#warmup_log(event, step, detail)`:
   - Use `logger.info` for `:complete` events
   - Use `logger.warn` for `:fail` events
   - No user-facing Telegram messages (bot should appear instantly ready)
3. **Note:** Telegram warm-up blocks before `listen` since users don't observe bot startup. This ensures the first incoming message is fast.
4. **Handle** the Ollama provider reference: Telegram uses `Agent::ModelProvider` wrappers, not `OllamaProvider` directly. Warmup needs the raw OllamaProvider or should support ModelProvider. The simplest approach: Warmup should detect provider type and use the appropriate preload method — or Telegram builds a lightweight OllamaProvider for warm-up from the local model config.

**Acceptance Criteria:**

- GIVEN Telegram bot starts with warmup enabled, WHEN the bot starts, THEN models are preloaded before `@bot.listen` begins and warm-up results are logged.
- GIVEN Ollama is unreachable, WHEN warm-up runs, THEN the failure is logged and the bot starts normally.

**Technical Context:**

- Pattern: Follow existing `setup_components!` → `start` flow
- Files: `lib/homunculus/interfaces/telegram.rb`
- Dependencies: Stories 1, 2
- Note: Telegram uses `Agent::ModelProvider` wrappers; the Warmup module needs to handle this (or accept a lightweight OllamaProvider for the preload endpoint)

**Agent Hints:**

- Agent class: Builder (speed-class)
- Context files: `lib/homunculus/interfaces/telegram.rb`, `lib/homunculus/agent/warmup.rb`
- Validation: `bin/dev test spec/interfaces/telegram_spec.rb && bin/dev lint`

---

### Story 6: OllamaProvider Preload Method

**As a** developer, **I want** the OllamaProvider to have a dedicated `preload_model(model)` method **so that** warm-up can trigger model loading with minimal overhead (1 token) without repurposing `generate()`.

- **Timebox:** 0.5d
- **Risk:** P1 — Clean API boundary; prevents leaking warm-up concerns into generate().

**Action Plan:**

1. **Add** `OllamaProvider#preload_model(model)` method:
   ```ruby
   def preload_model(model)
     payload = {
       model: model,
       messages: [{ role: "user", content: "hi" }],
       stream: false,
       options: { num_predict: 1, temperature: 0 },
       keep_alive: @keep_alive
     }
     response = http_client.post("#{@base_url}/api/chat", json: payload)
     raise_if_error!(response)
     raise ProviderError, "Ollama preload returned #{response.status}" unless response.status == 200
     parsed = JSON.parse(response.body.to_s)
     {
       loaded: true,
       load_duration_ns: parsed["load_duration"],
       total_duration_ns: parsed["total_duration"]
     }
   end
   ```
2. **Test** `spec/agent/models/ollama_provider_spec.rb`:
   - Stub HTTP to return 200 with load_duration metadata
   - Verify minimal token generation (num_predict: 1)
   - Test failure handling (connection refused, timeout)

**Acceptance Criteria:**

- GIVEN an Ollama instance with the model available, WHEN `preload_model("qwen2.5:14b")` is called, THEN it sends a minimal chat request (1 token) and returns load duration metadata.
- GIVEN Ollama is unreachable, WHEN `preload_model` is called, THEN it raises `ProviderError`.

**Technical Context:**

- Pattern: Follow existing `generate()` and `model_loaded?()` patterns
- Files: `lib/homunculus/agent/models/ollama_provider.rb`, `spec/agent/models/ollama_provider_spec.rb`
- Dependencies: None (can be done in parallel with Story 2)

**Agent Hints:**

- Agent class: Builder (speed-class)
- Context files: `lib/homunculus/agent/models/ollama_provider.rb`
- Validation: `bin/dev test spec/agent/models/ollama_provider_spec.rb && bin/dev lint`

---

## Execution Sequence

```
Story 2 (Config) ──┐
                    ├──▶ Story 1 (Warmup Core) ──▶ Story 3 (CLI) ──▶ Story 4 (TUI) ──▶ Story 5 (Telegram)
Story 6 (Preload) ─┘
```

Stories 2 and 6 can be done in parallel (no dependency between them).
Stories 3, 4, 5 can also be done in parallel after Story 1 is complete, but sequential execution is simpler for testing.

**Estimated total:** ~5.5 days

---

## Confidence Assessment

| Factor (25% each) | Score | Rationale |
|---|---|---|
| Pattern match | 75% | No existing warm-up pattern in codebase, but HealthMonitor and ActivityIndicator provide strong reference. Standard preloading pattern is well-understood. |
| Requirement clarity | 95% | Root causes are well-identified. Interface behaviors are specified. Config schema is defined. |
| Decomposition stability | 85% | 6 stories with clear boundaries. Core module + interface integrations is a proven decomposition. |
| Constraint compliance | 90% | No new dependencies. Follows project code style. Tests specified for each story. Config is extensible. |

**Overall confidence: 86%** → AUTO_PROCEED

The plan is well-specified with low ambiguity. The main risk is Ollama API behavior nuances (model loading with minimal prompts), which is mitigated by the graceful degradation design — if preload fails, behavior is identical to today.

---

## Preflight Checklist

- [x] CLARIFY: Intent unambiguous, constraints explicit — skip justified
- [x] Complexity scored: 8/12, extended reasoning budget
- [x] 4 genuinely distinct hypotheses explored (H1–H5 with H4 merged)
- [x] All stories pass INVEST (Independent, Negotiable, Valuable, Estimable, Small, Testable)
- [x] All timeboxes valid (0.5d–2d, no >8d)
- [x] Hierarchy uses Project (not "Epic")
- [x] Acceptance criteria in GIVEN/WHEN/THEN
- [x] Agent hints with context files per story
- [x] Dual output: Markdown (this file) — YAML deferred to execution
- [x] Confidence score present with factor breakdown
- [x] Plan saved as artifact
- [x] No code produced (plans only)
- [x] Rejected alternatives documented

---

*SPECTRA v4.2.0 — Generated 2025-03-08*
