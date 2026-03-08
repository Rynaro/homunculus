# SAG Seamless Integration Fix

## Context

The `web_research` tool (backed by the SAG pipeline) exists as a fully implemented class at `lib/homunculus/tools/web_research.rb` with all SAG pipeline components (`QueryAnalyzer`, `Retriever`, `Reranker`, `GroundedGenerator`, `PostProcessor`) in `lib/homunculus/sag/`. However, the tool is **never registered** in any interface's tool registry (TUI, CLI, or Telegram). Additionally, the `Models::Router` keyword detection routes messages containing "research" to tiers whose models may not be loaded in Ollama, producing a 400 HTTP error that surfaces as a hard crash in the TUI.

## Root Cause Analysis

1. **Missing tool registration**: `build_tool_registry` in TUI (`tui.rb:199`), CLI (`cli.rb:129`), and Telegram (`telegram.rb:159`) never calls `registry.register(Tools::WebResearch.new(pipeline_factory: ...))`.

2. **Missing pipeline factory**: The `WebResearch` tool requires a `pipeline_factory:` callable that constructs a `SAG::Pipeline` per invocation. No factory builder exists in any interface.

3. **Missing LLM adapter**: The SAG's `GroundedGenerator` and `QueryAnalyzer` use `@llm.call(prompt, max_tokens:)` — a simple callable interface. No adapter exists to bridge this to the `Models::Router` or `ModelProvider`.

4. **Keyword routing collision**: The `Models::Router.detect_tier_from_keywords` may route "research" to a tier with an unloaded model, causing Ollama to return HTTP 400 before any tool execution even begins.

5. **No visual feedback**: No SAG-specific activity indicator exists in the TUI. Tool execution steps are invisible to the user.

---

## SPECTRA Summary

- **Intent:** BUG_SPEC — Root cause → fix spec for SAG integration failure.
- **Complexity:** 6/12 — Standard. Multiple files, known patterns, clear scope.
- **Pattern:** ADAPT — The SAG pipeline, tool base class, and tool registry patterns are all established. Wire them together and add graceful degradation.
- **Approach:** Register the tool conditionally (when SAG is enabled), build a pipeline factory that adapts the existing LLM provider to the SAG callable interface, add a `status_callback` to the agent loop for TUI activity indication during tool execution.

### Rejected Alternatives

| Alternative | Why Rejected |
|------------|--------------|
| Give SAG its own dedicated Ollama connection | Duplicates provider infrastructure; violates Internal First. The existing `Models::Router` or `ModelProvider` already manages Ollama. |
| Bypass keyword routing for "research" messages | Treats the symptom, not the cause. The tool needs to be properly registered so the LLM can invoke it through the normal tool_use flow. |
| Register all SAG sub-steps as separate tools | Over-engineers the interface. The pipeline is an implementation detail; the user interacts with `web_research` as a single tool. |

---

## Stories

### Story 1: Build SAG LLM Adapter & Pipeline Factory

**As a** developer, **I want** a reusable factory that constructs SAG pipelines wired to the existing LLM provider **so that** the `web_research` tool can function in any interface.

- **Timebox:** 1d
- **Risk:** P0 — Prerequisite for all other stories.

**Action Plan:**

1. **Create** `lib/homunculus/sag/llm_adapter.rb` — A callable class that wraps either `Models::Router#generate` or the legacy `ModelProvider#complete` into the `@llm.call(prompt, max_tokens:)` interface the SAG pipeline expects.
   - Constructor: `LLMAdapter.new(router:, model:)` or `LLMAdapter.new(provider:)`
   - `#call(prompt, max_tokens: 1024)` → sends messages to the provider, returns the text content string.
   - The adapter must use a fixed tier (e.g., `:workhorse`) to avoid keyword routing recursion (the word "research" in the grounding prompt must not trigger re-routing).

2. **Create** `lib/homunculus/sag/pipeline_factory.rb` — Constructs a `SAG::Pipeline` from config and an LLM adapter.
   - Constructor: `PipelineFactory.new(config:, llm_adapter:, embedder: nil)`
   - `#call(deep_fetch: false)` → returns a fully-wired `SAG::Pipeline` instance.
   - Wires: `SearchBackend::SearXNG` from config, `Retriever` with deep_fetch toggle, `Reranker` with optional embedder, `GroundedGenerator` with LLM adapter, `PostProcessor`.

**Acceptance Criteria:**

- GIVEN a config with SAG enabled, WHEN PipelineFactory#call is invoked, THEN it returns a Pipeline with all components wired.
- GIVEN an LLMAdapter wrapping the Models::Router, WHEN called with a prompt, THEN it returns the text content from the Ollama provider using the workhorse tier (no keyword routing).

**Technical Context:**

- `GroundedGenerator` calls `@llm.call(prompt, max_tokens: @max_tokens)` expecting a String response.
- `QueryAnalyzer` optionally calls `@llm.call(prompt, max_tokens: 256)` — same interface.
- The `Models::Router#generate` accepts `tier:` override, which bypasses keyword detection. Use `tier: :workhorse`.
- Files: NEW `lib/homunculus/sag/llm_adapter.rb`, NEW `lib/homunculus/sag/pipeline_factory.rb`

---

### Story 2: Register web_research Tool in Interfaces

**As a** user, **I want** the `web_research` tool to be available when SAG is enabled **so that** the agent can research topics on my behalf.

- **Timebox:** 0.5d
- **Risk:** P0 — Without registration, the tool is invisible to the LLM.
- **Depends on:** Story 1

**Action Plan:**

1. **Modify** `build_tool_registry` in TUI, CLI, and Telegram to conditionally register `WebResearch`:
   - Check `@config.sag.enabled` — only register if true.
   - Build the LLM adapter from the available provider (models_router path or legacy provider path).
   - Build the pipeline factory with config and adapter.
   - Call `registry.register(Tools::WebResearch.new(pipeline_factory: factory))`.

2. **Ensure** the LLM adapter uses the correct provider for each interface:
   - **TUI with models_router**: Adapter wraps `@models_router` (not yet constructed at registry-build time — reorder initialization or pass lazily).
   - **TUI/CLI legacy mode**: Adapter wraps the `@provider` (`ModelProvider` instance).
   - **Telegram**: Adapter wraps the `@providers[:ollama]` provider.

3. **Handle** initialization ordering: the tool registry is built before the models_router in the TUI. Either reorder setup_components! or use a lazy lambda for the LLM adapter.

**Acceptance Criteria:**

- GIVEN `sag.enabled = true` in config, WHEN the TUI starts, THEN the tool registry includes `web_research`.
- GIVEN `sag.enabled = false` in config, WHEN the TUI starts, THEN the tool registry does NOT include `web_research`.
- GIVEN the agent is asked to research a topic, WHEN the LLM generates a `web_research` tool call, THEN the tool executes via the SAG pipeline.

**Technical Context:**

- TUI `setup_components!` (tui.rb:86-112): builds registry at line 89, models_router at line 97-155.
- The pipeline_factory needs the LLM adapter which needs the models_router. Reorder: build models_router first, then registry.
- Files: EDIT `lib/homunculus/interfaces/tui.rb`, EDIT `lib/homunculus/interfaces/cli.rb`, EDIT `lib/homunculus/interfaces/telegram.rb`

---

### Story 3: Add Status Callback for TUI Activity During Tool Execution

**As a** user, **I want** to see what the agent is doing during tool execution (especially SAG operations) **so that** I know the system is working and not frozen.

- **Timebox:** 1d
- **Risk:** P1 — Missing visual feedback makes long SAG operations (search + fetch + generate) feel broken.
- **Depends on:** Story 2

**Action Plan:**

1. **Add** `status_callback:` optional parameter to `Agent::Loop` constructor.
   - Store as `@status_callback`.
   - In `execute_tool`, before executing: `@status_callback&.call(:tool_start, tool_call.name)`.
   - After executing: `@status_callback&.call(:tool_end, tool_call.name)`.

2. **Modify** TUI to provide a status_callback lambda:
   - When `:tool_start` received: `@activity_indicator.update("Running #{name}...")`.
   - When `:tool_end` received: `@activity_indicator.update("Processing results...")`.
   - The existing "Thinking..." → first-chunk-stops flow remains unchanged.

3. **Pass** the status_callback through `build_loop_with_models_router` and the legacy path.

**Acceptance Criteria:**

- GIVEN the agent calls `web_research`, WHEN the tool begins executing, THEN the activity indicator shows "Running web_research...".
- GIVEN the tool finishes, WHEN the agent processes results, THEN the indicator shows "Processing results...".
- GIVEN non-SAG tools, WHEN they execute, THEN the indicator also shows their name (generic benefit).

**Technical Context:**

- `ActivityIndicator` already exists with `start(message)`, `update(message)`, `stop` methods.
- The `execute_tool` method is in `loop.rb:467-513`.
- Files: EDIT `lib/homunculus/agent/loop.rb`, EDIT `lib/homunculus/interfaces/tui.rb`

---

### Story 4: Graceful Degradation

**As a** user, **I want** the agent to handle SAG failures gracefully **so that** unavailable SearXNG or network issues don't crash my session.

- **Timebox:** 0.5d
- **Risk:** P1 — Production resilience.
- **Depends on:** Story 1

**Action Plan:**

1. **Modify** `PipelineFactory#call` to handle SearXNG unavailability:
   - The `SearXNG#search` already returns `[]` on failure (line 46-48 of searxng.rb). This means the pipeline returns `PipelineResult.error("No search results found")`. This is already graceful — verify it propagates as a clean tool result.

2. **Verify** the `WebResearch#execute` error handling:
   - Line 48-49: `rescue StandardError => e` → `Result.fail("Web research error: #{e.message}")`. This is good.
   - Ensure LLMAdapter failures (Ollama down, timeout) are caught and produce a meaningful error message.

3. **Add** LLM adapter error wrapping:
   - In `LLMAdapter#call`, rescue `ProviderError` and convert to a clear message: "Research generation unavailable — LLM error: #{e.message}".

**Acceptance Criteria:**

- GIVEN SearXNG is unreachable, WHEN web_research is called, THEN the tool returns a failure result with "No search results found", and the agent responds helpfully.
- GIVEN Ollama is overloaded, WHEN the SAG generator calls the LLM, THEN the tool returns a failure result, not a crash.

---

## Execution Sequence

```
Story 1 (LLM Adapter + Pipeline Factory)   ──── prerequisite for all
    │
    ├── Story 2 (Register in Interfaces)    ──── depends on Story 1
    │       │
    │       └── Story 3 (Status Callback)   ──── depends on Story 2
    │
    └── Story 4 (Graceful Degradation)      ──── depends on Story 1
```

**Recommended order:** 1 → 4 → 2 → 3

---

## Files Changed

| Action | File | Stories |
|--------|------|---------|
| NEW | `lib/homunculus/sag/llm_adapter.rb` | 1, 4 |
| NEW | `lib/homunculus/sag/pipeline_factory.rb` | 1 |
| EDIT | `lib/homunculus/interfaces/tui.rb` | 2, 3 |
| EDIT | `lib/homunculus/interfaces/cli.rb` | 2 |
| EDIT | `lib/homunculus/interfaces/telegram.rb` | 2 |
| EDIT | `lib/homunculus/agent/loop.rb` | 3 |
| NEW | `spec/sag/llm_adapter_spec.rb` | 1 |
| NEW | `spec/sag/pipeline_factory_spec.rb` | 1 |

---

## Confidence Report

| Factor | Score | Notes |
|--------|-------|-------|
| Pattern match | 90% | SAG pipeline, tool base, registry — all established patterns |
| Requirement clarity | 90% | Root cause identified; fix path clear |
| Decomposition stability | 85% | Linear dependency chain; stories independent enough |
| Constraint compliance | 90% | No new gems; graceful degradation; security unchanged |
| **Overall** | **89%** | **AUTO_PROCEED** |
