# CI Stability Fix — Discovery & Handoff

**Date**: 2026-03-10
**Context**: Branch segregation ([500cfcb6](agent-transcripts/500cfcb6-12a5-41c2-99ea-98bbfa3c9cfb)) merged feat/adaptive-web-phase1, fix/web-tool-selection, feat/searxng-bootstrap to main. Remote CI reports linter and test failures. These did not occur before the split.

---

## Linter (1 offense)

| File | Line | Cop | Fix |
|------|------|-----|-----|
| `lib/homunculus/tools/web_strategy.rb` | 70 | Layout/EmptyLineAfterGuardClause | Add empty line after `return false if u.empty?` |

**Autocorrectable**: Yes — `bin/dev lint -A` fixes it.

---

## Test Failures (21 total)

### 1. `spec/tools/web_spec.rb` — 10 failures

**Root causes**:

| # | Example | Line | Root Cause |
|---|---------|------|------------|
| 1 | SSRF protection allows requests to public IPs | 136 | Body 95 chars < MIN_BODY_THRESHOLD (100) → INCOMPLETE_HTML → result.success = false |
| 2 | rate limiting allows requests within rate limit | 155 | Body "ok" (2 chars) → INCOMPLETE_HTML → fail |
| 3 | HTML extraction strips HTML tags | 196 | HTML ~170 chars but may hit classification edge case |
| 4 | executes PUT requests | 287 | Same: body or classification |
| 5 | executes POST requests | 271 | Same |
| 6 | defaults to GET when method not specified | 302 | Same |
| 7 | fetch_mode and response_classification on success | 321 | Body 95 chars < 100 → INCOMPLETE_HTML |
| 8 | failure_reason auth_required when 200 body has login | 362 | Body 45 chars < 100 → INCOMPLETE_HTML (not AUTH_REQUIRED) |
| 9 | failure_reason js_required when 200 body is minimal | 377 | Body 43 chars < 100 → INCOMPLETE_HTML (not JS_REQUIRED) |
| 10 | session cookie persistence stateless mode | 456 | Body / classification |

**Classification order bug** (`lib/homunculus/tools/web_classification.rb`):

`classify_200_body` checks INCOMPLETE_HTML **before** AUTH_REQUIRED and JS_REQUIRED:

```ruby
return { failure_reason: INCOMPLETE_HTML } if body.length < MIN_BODY_THRESHOLD  # 1st
return { failure_reason: AUTH_REQUIRED } if auth_indicators_match?(text)       # 2nd
return { failure_reason: JS_REQUIRED } if js_required?(body)                   # 3rd
```

Short bodies with auth indicators (e.g. "Please log in") or minimal HTML get INCOMPLETE_HTML instead of the expected semantic classification.

**Raw-mode behavior**: For `mode: "raw"` (APIs), body-based classification (INCOMPLETE_HTML, JS_REQUIRED, AUTH_REQUIRED) should not apply — APIs can return small valid responses.

### 2. `spec/interfaces/cli_warmup_spec.rb` — 11 failures

**Root cause**: All failures are `WebMock::NetConnectNotAllowedError`.

**Call path**: `CLI#initialize` → `setup_components!` → `build_tool_registry` → `register_sag_tool` (when `sag.enabled`) → `sag_backend_available?` → `SearXNG#available?` → real `GET http://host.docker.internal:8888/healthz`.

**Fix options**:
- **A**: Set `sag.enabled = false` in cli_warmup_spec config (simplest)
- **B**: Stub `stub_request(:get, %r{.*/healthz}).to_return(status: 200)`
- **C**: Stub `SAGReachability#sag_backend_available?` or `SearXNG#available?` to return true/false

---

## Proposed Fixes (for Planner validation)

### Linter
- Apply `bin/dev lint -A` or manually add blank line in web_strategy.rb:70.

### WebClassification
- **Reorder** `classify_200_body`: check AUTH_INDICATORS and `js_required?` **before** MIN_BODY_THRESHOLD.
- **Rationale**: Auth/login and minimal-skeleton semantics take precedence over length.

### Raw mode
- In `handle_classification_failure` (or equivalent), for `mode == "raw"` do **not** fail on INCOMPLETE_HTML, JS_REQUIRED, AUTH_REQUIRED — only on BLOCKED_BOT, RATE_LIMITED, TIMEOUT.
- **Rationale**: Raw mode fetches APIs; small or non-HTML responses are valid.

### CLI warmup spec
- Add `sag.enabled = false` to the spec config in `cli_warmup_spec.rb` (or stub SearXNG health check).
- **Rationale**: Warmup specs focus on warmup behavior; SAG reachability is orthogonal and covered elsewhere.

---

## Files to Modify

| File | Change |
|------|--------|
| `lib/homunculus/tools/web_strategy.rb` | Add blank line after guard (lint) |
| `lib/homunculus/tools/web_classification.rb` | Reorder classify_200_body checks |
| `lib/homunculus/tools/web.rb` | Skip body-based classification failure for raw mode |
| `spec/interfaces/cli_warmup_spec.rb` | Disable sag in config or stub healthz |

---

## Verification

- `bin/dev test` → 0 failures
- `bin/dev lint` → 0 offenses
- Coverage remains ≥75%

---

# SPECTRA Plan Output (2026-03-10)

## SCOPE

| Attribute | Value |
|-----------|-------|
| **Intent type** | BUG_SPEC (regression fix) |
| **Complexity** | 4/12 (standard processing) |
| **Scope** | Single feature — CI stability |
| **Boundaries** | In: linter + 21 test failures. Out: new features, coverage expansion. Deferred: js_required? heuristic refinement if HTML extraction still fails after main fixes. |

### Complexity Scoring (1–3 per dimension)

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| Scope | 1 | Single regression fix across 4 files |
| Ambiguity | 1 | Discovery artifact provides full catalog and root causes |
| Dependencies | 1 | Isolated — tools, interfaces, config; no cross-domain |
| Risk | 1 | Low — CI gate only; behavior changes restore intended semantics |

---

## CONSTRUCT — Story Hierarchy

### Theme: CI Stability After Merge

### Project: Regression Fix (Post-Branch-Merge)

### Story 1 — Linter: Layout/EmptyLineAfterGuardClause

**User story:** As a maintainer, I want zero RuboCop offenses so that CI passes and the codebase adheres to style conventions.

**Timebox:** 1d  
**Risk tag:** P2 (cosmetic)

**Action plan:** Modify `lib/homunculus/tools/web_strategy.rb` — add one blank line after the guard clause at line 69 (`return false if u.empty?`).

**Acceptance criteria:**
- GIVEN `web_strategy.rb` with the guard at line 69
- WHEN `bin/dev lint` is run
- THEN zero offenses; Layout/EmptyLineAfterGuardClause satisfied

**Technical context:** Autocorrectable via `bin/dev lint -A`; manual fix = insert newline between line 69 and 70.

**Agent hints:** Builder (speed-class); context: `web_strategy.rb`; validation: `bin/dev lint`.

---

### Story 2 — WebClassification: Reorder classify_200_body Checks

**User story:** As a user of web_fetch, I want auth indicators and JS-skeleton detection to take precedence over body length so that "Please log in" is classified as AUTH_REQUIRED and minimal HTML as JS_REQUIRED, not INCOMPLETE_HTML.

**Timebox:** ≤2d  
**Risk tag:** P1 (degrades experience if wrong)

**Action plan:**
1. In `lib/homunculus/tools/web_classification.rb`, reorder `classify_200_body`:
   - Check `auth_indicators_match?(text)` first → AUTH_REQUIRED
   - Check `js_required?(body)` second → JS_REQUIRED
   - Check `body.length < MIN_BODY_THRESHOLD` third → INCOMPLETE_HTML
   - Else → SUCCESS
2. Preserve exact semantics of each predicate; no logic changes.

**Acceptance criteria:**
- GIVEN a 200 response with body containing "Please log in" (length < 100)
- WHEN classify_200_body is called
- THEN failure_reason is AUTH_REQUIRED (not INCOMPLETE_HTML)
- GIVEN a 200 response with minimal HTML skeleton (e.g. `<html><head></head><body></body></html>`, length < 100)
- WHEN classify_200_body is called
- THEN failure_reason is JS_REQUIRED (not INCOMPLETE_HTML)
- GIVEN a 200 response with no auth indicators, not js_required, and body length < 100
- WHEN classify_200_body is called
- THEN failure_reason is INCOMPLETE_HTML

**Technical context:** Current order (lines 56–58): INCOMPLETE_HTML → AUTH_REQUIRED → JS_REQUIRED. New order: AUTH_REQUIRED → JS_REQUIRED → INCOMPLETE_HTML.

**Agent hints:** Builder; context: `web_classification.rb`; validation: `bin/dev test spec/tools/web_spec.rb`.

**Contingency:** If "HTML extraction strips HTML tags" (spec line ~196) still fails because `js_required?` matches a ~170-char HTML page with real content, refine `js_required?` to exclude bodies with substantial text (e.g. after naive tag-strip, remaining text ≥ 50 chars → not JS_REQUIRED). Document as follow-up story if needed.

---

### Story 3 — WebFetch: Skip Body-Based Classification Failure for Raw Mode

**User story:** As a user calling web_fetch in raw mode for APIs, I want small or non-HTML responses to succeed so that JSON/XML API responses are returned without being blocked by HTML heuristics.

**Timebox:** ≤2d  
**Risk tag:** P1 (degrades experience if wrong)

**Action plan:** In `lib/homunculus/tools/web.rb`, inside `handle_classification_failure`, when `mode == "raw"` and `classification[:failure_reason]` is one of INCOMPLETE_HTML, JS_REQUIRED, AUTH_REQUIRED, return `nil` (no failure). For BLOCKED_BOT, RATE_LIMITED, TIMEOUT, retain current behavior (fail).

**Acceptance criteria:**
- GIVEN mode "raw", 200 response, body "ok" (2 chars)
- WHEN fetch_url runs
- THEN result.success is true; output is "ok"
- GIVEN mode "raw", 200 response, body `{"ok":true}` (small JSON)
- WHEN fetch_url runs
- THEN result.success is true
- GIVEN mode "raw", 403 response
- WHEN fetch_url runs
- THEN result.success is false; failure_reason is BLOCKED_BOT
- GIVEN mode "extract_text", 200 response, body "ok" (2 chars)
- WHEN fetch_url runs
- THEN result.success is false; failure_reason is INCOMPLETE_HTML (unchanged)

**Technical context:** `handle_classification_failure` at line 321–325; receives `classification` and `mode`; currently returns Result.fail for any non-SUCCESS. Add early return: `return nil if mode == "raw" && [INCOMPLETE_HTML, JS_REQUIRED, AUTH_REQUIRED].include?(classification[:failure_reason])`.

**Agent hints:** Builder; context: `web.rb` (WebFetch); validation: `bin/dev test spec/tools/web_spec.rb`.

---

### Story 4 — CLI Warmup Spec: Disable SAG to Avoid Net Connect

**User story:** As a developer running specs, I want cli_warmup_spec to run without real HTTP calls so that CI and local runs succeed without SearXNG.

**Timebox:** 1d  
**Risk tag:** P2 (cosmetic — spec isolation)

**Action plan:** In `spec/interfaces/cli_warmup_spec.rb`, add `raw["sag"] = { "enabled" => false }` to the config hash built in the `let(:config)` block (alongside existing overrides for agent, scheduler). This prevents `register_sag_tool` from calling `sag_backend_available?` → SearXNG health check.

**Acceptance criteria:**
- GIVEN cli_warmup_spec config with sag.enabled = false
- WHEN `described_class.new(config:)` is invoked in any example
- THEN no real HTTP request to host.docker.internal:8888/healthz
- WHEN `bin/dev test spec/interfaces/cli_warmup_spec.rb` runs
- THEN all examples pass; zero WebMock::NetConnectNotAllowedError

**Technical context:** Config loads `config/default.toml`; sag.enabled defaults to true; CLI's `setup_components!` → `build_tool_registry` → `register_sag_tool` only when `@config.sag.enabled`; SAGReachability calls SearXNG#available? which performs GET to healthz.

**Agent hints:** Builder; context: `cli_warmup_spec.rb`, `config/default.toml`; validation: `bin/dev test spec/interfaces/cli_warmup_spec.rb`.

---

## TEST — 6-Layer Verification

### Layer 1: Structural
- **Hierarchy intact:** Theme → Project → 4 Stories. No orphaned tasks.
- **Stories independent:** 1 (lint), 2 (classification), 3 (raw mode), 4 (spec config) — no blocking dependencies. Stories 2 and 3 both touch web toolchain but are logically independent (2 = classification logic, 3 = handling in web.rb).
- **Gate:** PASS

### Layer 2: Self-Consistency
- **Alternative A:** Single story (batch all changes) vs. 4 stories. Overlap: same four changes, different granularity. Core actions identical.
- **Alternative B:** 2 stories (web + spec) vs. 4. Overlap: web = lint + classification + raw; spec = SAG. Same changes.
- **Alternative C:** 3 stories (lint | web-logic | spec). Overlap: same scope.
- **Overlap:** ~90% — decomposition stable.
- **Gate:** PASS

### Layer 3: Dependency
- **Affected files:** web_strategy.rb, web_classification.rb, web.rb, cli_warmup_spec.rb. All identified.
- **Call sites:** WebClassification.classify used only in web.rb; no other callers. handle_classification_failure private to WebFetch.
- **Migration paths:** N/A — no schema or config migration.
- **Gate:** PASS

### Layer 4: Constraint
- **NFRs:** RuboCop compliance, RSpec pass, coverage ≥75%. Addressed.
- **Timeboxes:** All ≤2d; realistic for small edits.
- **Security:** No auth/secrets changes; no sandbox or blocked_patterns changes. Body-based classification relaxation for raw mode is scoped and documented.
- **Gate:** PASS

### Layer 5: Process Reward
- **Ordering:** 1 (lint) → 2 (classification) → 3 (raw) → 4 (spec). Lint first reduces noise; classification + raw fix web_spec; spec fix isolates cli. Optimal.
- **Risk reduction:** Each story reduces failure count; final verification confirms zero.
- **Gate:** PASS

### Layer 6: Adversarial
- **Under-specification:** Stories have GIVEN/WHEN/THEN. Contingency for js_required? documented in Story 2.
- **Over-specification:** No rigid constraints blocking valid implementations.
- **Dependency blindness:** Config structure (raw["sag"]) validated against Homunculus::Config.
- **Assumption drift:** Discovery artifact is source of truth; no external changes assumed.
- **Scope creep:** Four fixes only; no tangential work.
- **Premature optimization:** Fixes are minimal; no architectural changes.
- **Stale context:** Plan based on current file reads (2026-03-10).
- **Gate:** PASS

---

## ASSEMBLE — Confidence Report

| Factor | Score (0–3) | Weight | Contribution |
|--------|-------------|--------|---------------|
| Pattern match | 3 | 25% | Standard regression fix pattern |
| Requirement clarity | 3 | 25% | Discovery artifact is comprehensive |
| Decomposition stability | 3 | 25% | ≥70% self-consistency |
| Constraint compliance | 3 | 25% | All 6 layers pass |

**Confidence:** 100% → **AUTO_PROCEED**

**Execution sequence:** 1 → 2 → 3 → 4. Run `bin/dev test` and `bin/dev lint` after all; confirm coverage ≥75%.

**Rejected alternatives documented:**
- Stub healthz (option B) vs. sag.enabled=false: Chose config override for simplicity and spec focus.
- Refine js_required? in same story: Deferred to contingency; keeps Story 2 scoped.
