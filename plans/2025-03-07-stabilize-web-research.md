# Stabilize web_research Tool Triggers

## Context

When a user types "Make a research about models fine-tunning" in the TUI, the system crashes with HTTP 400 from Ollama. The root cause is a 4-layer failure chain: keyword routing sends the request to `deepseek-r1:14b` (thinker tier), which doesn't support tool calling; escalation is unavailable because TUI only registers `:ollama`; and `web_research` isn't registered in TUI at all.

---

## SPECTRA Summary

- **Intent Type:** BUG_SPEC — multi-layer defect requiring fix spec across routing, error handling, and interface parity.
- **Complexity:** 8/12 (Scope: 2 multi-feature | Ambiguity: 1 clear | Dependencies: 3 cross-domain | Risk: 2 user-facing)
- **Thinking Budget:** Extended (2x).
- **Pattern:** ADAPT — Telegram's `SAGResearch` module (85% match for SAG extraction); CLI's `build_sag_*` methods as reference. Router enhancement is GENERATE (no prior pattern for tool-compatibility filtering).
- **Approach:** H2 — Router-level tool filtering + shared SAG concern module + improved error diagnostics (see Exploration below).

---

## Scope

**Boundaries:**

| In Scope | Out of Scope | Deferred |
|----------|--------------|----------|
| Router tool-compatibility awareness per tier | Changing model fleet composition | Anthropic provider registration in TUI |
| Strip tools from payload for incompatible tiers | SAG/SearXNG infrastructure changes | Auto-enabling SAG based on SearXNG availability |
| Shared SAG factory concern (DRY across interfaces) | UI changes to TUI rendering | Keyword signal tuning beyond `research` |
| TUI web_research tool registration | Telegram interface changes | Health monitor integration with tool compat |
| Improved error messages from OllamaProvider | Budget system changes | |
| Specs for all changed code | | |

**Assumptions:**
1. `deepseek-r1:14b` is the only current tier that lacks tool support — Risk if wrong: missed tier; mitigated by config-driven flag.
2. Stripping tools from the payload (and letting the model respond in plain text) is acceptable degraded behavior — Risk if wrong: user gets no tool calls when they expected web_research; mitigated by logging a warning.
3. The `SAGResearch` module pattern from Telegram can be generalized to all interfaces — Risk if wrong: low, CLI already has identical code.

---

## Pattern Analysis

| ID | Pattern | Similarity | Decision |
|----|---------|------------|----------|
| P1 | `Telegram::SAGResearch` module | 85% | USE_TEMPLATE — extract to shared concern |
| P2 | CLI `build_sag_*` methods | 90% (identical logic) | ADAPT — merge into shared module |
| P3 | Router `resolve_tier` + `execute_request` chain | 60% | ADAPT — add tool compat check in existing flow |
| P4 | OllamaProvider error handling pattern | 70% | ADAPT — enhance with body extraction |

**Strategy:** ADAPT — existing patterns cover SAG extraction well; router enhancement is new but fits existing architecture.

**Failure patterns from memory:** None directly applicable. The closest is "dependency blindness" — ensuring all call sites (TUI, CLI, Telegram) are updated when extracting the shared module.

---

## Exploration

### Observations
1. **Tool compatibility is a model property, not a provider property** — the issue is tier-specific, not Ollama-wide.
2. **The router already resolves tiers before calling providers** — the interception point exists.
3. **SAG code is copy-pasted across CLI and Telegram** — extraction is overdue.
4. **Error messages from HTTPX lose the response body** — `e.message` only has status, not the JSON error.
5. **The `research` keyword signal is the only one pointing to a tool-incompatible tier** — but the fix should be generic.

### Hypotheses

| # | Name | Feas | Value | Risk | Pattern | Timebox | Total |
|---|------|------|-------|------|---------|---------|-------|
| H1 | Config-only: remove `research` keyword signal | 3 | 1 | 1 | 1 | 3 | 9 |
| H2 | Router-level tool filtering + shared SAG + error improvement | 3 | 3 | 2 | 3 | 2 | 13 |
| H3 | Provider-level tool stripping in OllamaProvider | 2 | 2 | 3 | 2 | 3 | 12 |
| H4 | Thinker-to-workhorse auto-redirect when tools present | 2 | 2 | 2 | 2 | 2 | 10 |

**Expanded top 2:**

**H2 — Router-level tool filtering + shared SAG + error improvement:**
- Add `supports_tools` boolean to tier config in `models.toml` (declarative, per-tier).
- Router's `execute_request` strips `tools:` from the payload when `tier_config["supports_tools"] == false`.
- Log a warning so the user/developer knows tools were stripped.
- Extract SAG factory methods into `Homunculus::Interfaces::Concerns::SAGResearch` (shared module).
- Include in CLI, TUI, and Telegram.
- TUI's `build_tool_registry` registers `WebResearch` when SAG is enabled (guarded same as CLI).
- OllamaProvider's streaming rescue extracts HTTP response body for better diagnostics.
- **Files:** `config/models.toml`, `router.rb`, `ollama_provider.rb`, new `concerns/sag_research.rb`, `tui.rb`, `cli.rb`, plus specs.
- **Risk:** Medium — touching router is critical path, but change is additive (strip tools, don't change routing logic).

**H3 — Provider-level tool stripping in OllamaProvider:**
- OllamaProvider checks model name against a hardcoded or config list and strips tools.
- Simpler but couples tool awareness to the provider rather than the routing layer.
- Breaks separation of concerns — provider shouldn't know about tier semantics.
- **Risk:** Higher coupling; if a new provider is added, the pattern doesn't transfer.

**Selected:** H2 — Router-level tool filtering + shared SAG + error improvement
**Rationale:** Tool compatibility is a tier property (config-driven), not a provider implementation detail. The router already knows the tier — adding a single config flag and a conditional strip is minimal, testable, and doesn't pollute provider code. SAG extraction addresses the DRY violation that caused the TUI omission in the first place.

**Rejected:**
- H1: Band-aid. Removes research routing but doesn't fix the systemic issue. Any future tool-incompatible tier would hit the same crash.
- H3: Wrong layer. Provider shouldn't own tier-level semantics. Harder to test, harder to reason about.
- H4: Implicit behavior. Auto-redirecting thinker→workhorse is surprising; the user chose "thinker" for a reason (reasoning quality). Better to let the tier run without tools and respond in plain text.

---

## Stories (Execution Order)

### Phase 1: Foundation — Router Tool Compatibility

#### STORY: S-1 — Add tool compatibility flag to tier config

**Description:** As a developer, I want each model tier to declare whether it supports tool calling so that the router can make informed decisions about payload construction.

**Timebox:** 1d
**Risk:** P0 (blocks all other stories)

**Action Plan:**
1. **Modify:** `config/models.toml` — add `supports_tools = true` to whisper, workhorse, coder tiers; add `supports_tools = false` to thinker tier; add `supports_tools = true` to all cloud tiers.
2. **Modify:** `lib/homunculus/agent/models/router.rb` — in `execute_request`, check `tier_config["supports_tools"]`; when `false`, pass `tools: nil` to the provider call. Log a warning: "Tools stripped for tier [X] — model does not support tool calling".
3. **Test:** `spec/homunculus/agent/models/router_spec.rb` — add examples: tools stripped for thinker tier; tools passed for workhorse; warning logged.

**Acceptance Criteria:**
- [ ] GIVEN a request routed to `thinker` tier with tools in payload WHEN `execute_request` runs THEN tools are stripped (nil) before provider call
- [ ] GIVEN a request routed to `workhorse` tier with tools WHEN `execute_request` runs THEN tools are passed through unchanged
- [ ] GIVEN a tier with `supports_tools = false` WHEN tools are stripped THEN a warning is logged with tier name
- [ ] GIVEN a tier config missing `supports_tools` key WHEN `execute_request` runs THEN tools are passed through (default: true, backward compatible)

**Technical Context:**
- **Pattern:** Additive config flag with backward-compatible default
- **Files:** `config/models.toml`, `lib/homunculus/agent/models/router.rb`, `spec/homunculus/agent/models/router_spec.rb`
- **Dependencies:** None (foundation story)

**Agent Hints:**
- **Class:** builder
- **Context:** `config/models.toml`, `lib/homunculus/agent/models/router.rb:92-155` (execute_request + attempt_with_escalation), `spec/homunculus/agent/models/router_spec.rb`
- **Gates:** P0 checked; tests cover tools-present + tools-stripped + default behavior

---

#### STORY: S-2 — Improve OllamaProvider error diagnostics

**Description:** As a developer debugging production issues, I want HTTP error responses from Ollama to include the response body so that I can diagnose tool incompatibility and other API errors without checking Ollama logs.

**Timebox:** 1d
**Risk:** P1 (improves debuggability but not blocking)

**Action Plan:**
1. **Modify:** `lib/homunculus/agent/models/ollama_provider.rb` — in the `generate_stream` rescue block (line 102-108), attempt to extract and include HTTP status and response body in the error message. For HTTPX streaming errors, the response object may be available via the exception or the stream_response variable.
2. **Modify:** Detect HTTP 400 specifically and raise `PermanentProviderError` with a message indicating likely tool incompatibility: "Ollama returned 400 for model [X]. This model may not support tool calling. Check `supports_tools` in models.toml."
3. **Test:** `spec/homunculus/agent/models/ollama_provider_spec.rb` — add example for HTTP 400 during streaming raising `PermanentProviderError` with diagnostic message.

**Acceptance Criteria:**
- [ ] GIVEN a streaming request that receives HTTP 400 WHEN the error is caught THEN a `PermanentProviderError` is raised (not generic `ProviderError`)
- [ ] GIVEN any HTTP error during streaming WHEN the error message is constructed THEN it includes the HTTP status code and response body (if available)
- [ ] GIVEN a 400 error WHEN the error message is constructed THEN it suggests checking `supports_tools` in models.toml

**Technical Context:**
- **Pattern:** Enhance existing rescue block with response body extraction
- **Files:** `lib/homunculus/agent/models/ollama_provider.rb`, `spec/homunculus/agent/models/ollama_provider_spec.rb`
- **Dependencies:** Independent of S-1 (additive improvement)

**Agent Hints:**
- **Class:** builder
- **Context:** `lib/homunculus/agent/models/ollama_provider.rb:85-118` (streaming error handling), `lib/homunculus/utils/http_error_handling.rb`
- **Gates:** Tests cover 400 → PermanentProviderError, 500 → ProviderError, body included in message

---

### Phase 2: Shared SAG Concern + TUI Registration

#### STORY: S-3 — Extract shared SAG factory concern

**Description:** As a maintainer, I want the SAG pipeline factory methods to live in a single shared module so that adding web_research to any interface requires only an `include` and a guard clause, eliminating the copy-paste that caused the TUI omission.

**Timebox:** ≤2d
**Risk:** P0 (prerequisite for TUI registration)

**Action Plan:**
1. **Create:** `lib/homunculus/interfaces/concerns/sag_research.rb` — module `Homunculus::Interfaces::Concerns::SAGResearch` containing `build_sag_pipeline_factory`, `build_sag_embedder`, `build_sag_llm`. The `build_sag_llm` should use `@models_router` when available (as CLI does), falling back to direct provider call.
2. **Modify:** `lib/homunculus/interfaces/cli.rb` — remove inline `build_sag_pipeline_factory`, `build_sag_embedder`, `build_sag_llm` methods; add `include Concerns::SAGResearch`.
3. **Modify:** `lib/homunculus/interfaces/telegram/sag_research.rb` — either replace its body with `include Concerns::SAGResearch` or make it a thin wrapper that delegates to the shared module. Preserve the multi-provider fallback behavior (try ollama, then anthropic).
4. **Test:** `spec/homunculus/interfaces/concerns/sag_research_spec.rb` — unit test the factory methods: pipeline construction with embedder, pipeline construction without embedder, LLM lambda calls router when available.

**Acceptance Criteria:**
- [ ] GIVEN the shared module is included in CLI WHEN `build_sag_pipeline_factory` is called THEN it produces a working pipeline factory identical to the previous inline version
- [ ] GIVEN the shared module is included in TUI WHEN `@models_router` is available THEN `build_sag_llm` routes through the models router (workhorse tier, no tools)
- [ ] GIVEN the shared module is included in any interface WHEN `@config.sag.enabled` is false THEN no SAG components are instantiated
- [ ] GIVEN the shared module WHEN `build_sag_embedder` is called without a local model config THEN it returns nil gracefully

**Technical Context:**
- **Pattern:** Concern/mixin extraction (USE_TEMPLATE from Telegram's `SAGResearch`)
- **Files:** new `lib/homunculus/interfaces/concerns/sag_research.rb`, `lib/homunculus/interfaces/cli.rb`, `lib/homunculus/interfaces/telegram/sag_research.rb`, new spec
- **Dependencies:** None (can parallel with S-1)

**Agent Hints:**
- **Class:** builder
- **Context:** `lib/homunculus/interfaces/cli.rb:160-211` (existing SAG methods), `lib/homunculus/interfaces/telegram/sag_research.rb` (module pattern), `lib/homunculus/tools/web_research.rb` (consumer)
- **Gates:** CLI integration tests still pass; `bin/dev test` green

---

#### STORY: S-4 — Register web_research in TUI

**Description:** As a TUI user, I want the `web_research` tool to be available when SAG is enabled so that I can ask research questions through the TUI just like I can through the CLI.

**Timebox:** 1d
**Risk:** P1 (user-facing feature gap)

**Action Plan:**
1. **Modify:** `lib/homunculus/interfaces/tui.rb` — add `include Concerns::SAGResearch` and require the concern file.
2. **Modify:** `tui.rb#build_tool_registry` — after the memory tools block, add the same guarded registration as CLI: `registry.register(Tools::WebResearch.new(pipeline_factory: build_sag_pipeline_factory)) if @config.sag.enabled`.
3. **Test:** `spec/homunculus/interfaces/tui_spec.rb` (or integration) — verify that when `sag.enabled = true`, `web_research` appears in the tool registry; when false, it doesn't.

**Acceptance Criteria:**
- [ ] GIVEN SAG enabled in config WHEN TUI starts THEN `web_research` tool is present in the registry
- [ ] GIVEN SAG disabled in config WHEN TUI starts THEN `web_research` is not in the registry (no crash, no error)
- [ ] GIVEN SAG enabled and user sends research query WHEN routed to workhorse tier THEN tools include `web_research` and model can invoke it
- [ ] GIVEN SAG enabled WHEN `build_sag_llm` needs LLM inference THEN it uses `@models_router` (not a separate provider instance)

**Technical Context:**
- **Pattern:** Mirror CLI's tool registration, using shared concern
- **Files:** `lib/homunculus/interfaces/tui.rb`
- **Dependencies:** S-3 (shared SAG concern must exist)

**Agent Hints:**
- **Class:** builder
- **Context:** `lib/homunculus/interfaces/tui.rb:193-211` (build_tool_registry), `lib/homunculus/interfaces/cli.rb:154-157` (reference registration)
- **Gates:** TUI boots cleanly with SAG enabled; tool appears in registry

---

### Phase 3: Integration Verification

#### STORY: S-5 — End-to-end routing + tool compatibility specs

**Description:** As a developer, I want integration-level specs that verify the full message flow — keyword routing → tier resolution → tool stripping → provider call — so that regressions in this critical path are caught automatically.

**Timebox:** ≤2d
**Risk:** P1 (regression prevention)

**Action Plan:**
1. **Create:** `spec/integration/tool_routing_spec.rb` — integration spec exercising the Router with mocked OllamaProvider:
   - Message containing "research" → resolves to thinker → tools stripped → no HTTP error.
   - Message containing "code" → resolves to coder → tools passed through.
   - Message with no keywords → workhorse → tools passed through.
2. **Extend:** `spec/homunculus/agent/models/router_spec.rb` — add edge cases: tier config missing `supports_tools` key defaults to true; escalation from tool-stripped tier works correctly.
3. **Verify:** Run `bin/dev test` full suite to ensure no regressions.

**Acceptance Criteria:**
- [ ] GIVEN "research" keyword in message WHEN routed through full Router THEN thinker tier selected AND tools are nil in provider call
- [ ] GIVEN "code" keyword in message WHEN routed through full Router THEN coder tier selected AND tools are present
- [ ] GIVEN thinker tier returns an error despite tool stripping WHEN escalation is enabled THEN escalation fires normally
- [ ] GIVEN full test suite WHEN `bin/dev test` runs THEN all pass with ≥75% coverage

**Technical Context:**
- **Pattern:** Integration spec pattern (Router + mocked Provider)
- **Files:** new `spec/integration/tool_routing_spec.rb`, `spec/homunculus/agent/models/router_spec.rb`
- **Dependencies:** S-1 (tool compat in router), S-2 (error handling)

**Agent Hints:**
- **Class:** builder
- **Context:** `spec/homunculus/agent/models/router_spec.rb` (existing patterns), `lib/homunculus/agent/models/router.rb`
- **Gates:** Full suite green; coverage maintained

---

## Verification Report

| Layer | Check | Status |
|-------|-------|--------|
| Structural | Hierarchy intact (1 project, 2 features, 5 stories), stories independent within phases | PASS |
| Self-Consistency | 3 decompositions explored; ~80% overlap on core stories (router compat + SAG extraction + TUI registration always present) | PASS |
| Dependency | All affected files identified: `models.toml`, `router.rb`, `ollama_provider.rb`, `tui.rb`, `cli.rb`, `telegram/sag_research.rb`, new concern. Call sites for `execute_request` and `build_tool_registry` covered. | PASS |
| Constraint | Budget checks untouched; SAG guarded by config flag; no changes to sandbox, MQTT, or audit systems | PASS |
| Process Reward | Phase 1 (router safety) blocks nothing and reduces crash risk immediately; Phase 2 (SAG DRY) enables TUI; Phase 3 (specs) prevents regression | PASS |
| Adversarial | "What if another tier is added without `supports_tools`?" → default true is safe (backward compat). "What if SAG factory raises during TUI boot?" → guarded by `if @config.sag.enabled`, and factory is lazy (built on first use). "What if deepseek-r1 adds tool support later?" → just flip config flag. | PASS |

**Self-Consistency:** 80% overlap across decompositions.
**Constraints:** 6/6 passed.
**Gate:** PASS — proceed to Assemble.

---

## Refinement

No refinement cycles needed. All verification layers passed on first evaluation.

| Dimension | Score |
|-----------|-------|
| Clarity | 5 |
| Completeness | 5 |
| Actionability | 5 |
| Efficiency | 4 |
| Testability | 5 |

---

## Confidence Assessment

| Factor | Score |
|--------|-------|
| Pattern Match | 3/3 — Telegram SAGResearch is nearly identical; CLI methods are 1:1 |
| Requirement Clarity | 3/3 — Root cause fully traced through 4 layers with file:line references |
| Decomposition Stability | 2/3 — Core stories stable; SAG module boundary could go concern vs. base class |
| Constraint Compliance | 3/3 — No budget, sandbox, audit, or security changes |

**Weighted Confidence:** 92%
**Decision:** AUTO_PROCEED

---

## Files Changed

| Action | File |
|--------|------|
| EDIT | `config/models.toml` — add `supports_tools` per tier |
| EDIT | `lib/homunculus/agent/models/router.rb` — strip tools for incompatible tiers |
| EDIT | `lib/homunculus/agent/models/ollama_provider.rb` — improve streaming error diagnostics |
| NEW | `lib/homunculus/interfaces/concerns/sag_research.rb` — shared SAG factory module |
| EDIT | `lib/homunculus/interfaces/tui.rb` — include SAG concern, register web_research |
| EDIT | `lib/homunculus/interfaces/cli.rb` — replace inline SAG methods with shared concern |
| EDIT | `lib/homunculus/interfaces/telegram/sag_research.rb` — delegate to shared concern |
| NEW | `spec/homunculus/interfaces/concerns/sag_research_spec.rb` |
| NEW | `spec/integration/tool_routing_spec.rb` |
| EDIT | `spec/homunculus/agent/models/router_spec.rb` — add tool compat examples |
| EDIT | `spec/homunculus/agent/models/ollama_provider_spec.rb` — add 400 error example |

---

## Technical Notes

- **Default for `supports_tools`:** When the key is missing from tier config, the router should default to `true`. This preserves backward compatibility — existing `models.toml` files without the key continue working.
- **Tool stripping location:** Inside `execute_request` (router.rb), not in `attempt_with_escalation`. This ensures the stripping happens at the lowest level before the provider call, and escalation can still pass tools if the cloud tier supports them.
- **SAG LLM routing:** The shared concern's `build_sag_llm` should explicitly pass `tier: :workhorse` and `tools: nil` to the models router, ensuring SAG's internal LLM calls never trigger tool definitions (avoiding recursive tool calling).
- **`research` keyword remains:** The keyword signal `research = "thinker"` stays in `models.toml`. The thinker tier is still the best model for research reasoning — it just won't receive tools. The model will respond in plain text, which is appropriate for research synthesis.
