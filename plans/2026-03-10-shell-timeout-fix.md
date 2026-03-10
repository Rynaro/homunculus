# Shell Timeout Fix — Plan Artifact

**Date:** 2026-03-10  
**Intent Type:** BUG_SPEC  
**Source:** `.claude/context/shell-timeout-investigation.md`  
**SPECTRA Phase:** ASSEMBLE

---

## 1. Scope

### Summary

**Error:** `Shell execution error: wrong exec option symbol: timeout`  
**Root Cause:** `Open3.capture3` forwards its options hash to `Process.spawn`. Ruby's `Process.spawn` exec options do **not** include `:timeout`. Passing `timeout:` causes `ArgumentError`.

### Boundaries

| Category | Items |
|----------|-------|
| **In Scope** | Replace `Open3.capture3(..., timeout:)` with `Timeout.timeout(sec) { Open3.capture3(...) }` in shell.rb and sandbox.rb; update shell_spec stubs |
| **Out of Scope** | Behavioral changes to timeout logic; new timeout APIs; timeout configuration changes |
| **Deferred** | N/A |

### Complexity Score: 4

- Scope: 1 (single bug fix)
- Ambiguity: 1 (requirements explicit, fix specified)
- Dependencies: 1 (shell + sandbox isolated)
- Risk: 1 (low; existing `rescue Timeout::Error` unchanged)

**Route:** Standard processing.

### Assumptions

| Assumption | Risk if Wrong |
|------------|---------------|
| `Timeout` module is in stdlib (no gem) | Low — loop.rb already uses it |
| `rescue Timeout::Error` blocks continue to work | None — Timeout.timeout raises same exception |
| No other callers pass `timeout:` to Open3 | Low — grep confirms only these 4 sites |

---

## 2. Pattern

**Strategy:** USE_TEMPLATE (≥85% match)

Existing pattern in `lib/homunculus/agent/loop.rb` (line 481):

```ruby
result = Timeout.timeout(@config.agent.max_execution_time_seconds) do
  @tools.execute(...)
end
```

Apply same pattern: wrap `Open3.capture3` with `Timeout.timeout(timeout)`.

---

## 3. Explore — Hypotheses

| # | Strategy | Alignment | Correctness | Maintainability | Simplicity | Risk | Score | Notes |
|---|----------|-----------|-------------|-----------------|------------|------|-------|-------|
| 1 | **Direct Timeout.timeout wrapper** per call site | 10 | 10 | 9 | 10 | 10 | **~92** | Minimal change; proven in loop.rb |
| 2 | **Shared helper** `capture3_with_timeout(cmd, timeout)` in Utils | 9 | 10 | 10 | 8 | 10 | **~88** | DRY but 4 call sites doesn't justify new abstraction |
| 3 | **Process.spawn + custom timeout** (separate thread) | 7 | 8 | 6 | 4 | 7 | **~65** | Over-engineered; Timeout module is standard |

**Selected:** Hypothesis 1 — Direct Timeout.timeout wrapper.

**Rationale:** Matches existing loop.rb pattern exactly; minimal diff; no new abstractions; `Timeout::Error` handling already in place.

**Rejected Alternatives:**
- Hypothesis 2: Premature abstraction; only 2 files affected.
- Hypothesis 3: Unnecessary complexity; Ruby stdlib `Timeout` is adequate.

---

## 4. Approach

Replace invalid `timeout:` kwarg with `Timeout.timeout(seconds)` wrapper:

```ruby
# Before (broken):
stdout, stderr, status = Open3.capture3(*docker_cmd, timeout:)

# After (correct):
stdout, stderr, status = Timeout.timeout(timeout) { Open3.capture3(*docker_cmd) }
```

- Add `require "timeout"` where missing (shell.rb, sandbox.rb).
- Keep all `rescue Timeout::Error` blocks unchanged.
- Update specs: remove `timeout:` from stub expectations; timeout-related specs must assert on `Timeout.timeout` being called or on behavioral outcome.

---

## 5. Story Hierarchy

### PROJECT: Shell Timeout Bug Fix

#### FEATURE: Replace Invalid Open3 Timeout Option

##### STORY 1: Fix shell.rb — Docker and local execution (≤1d)

**As a** user invoking `shell_exec`, **I want** commands to run with a timeout **so that** long-running commands are killed and I receive a clear error.

- **Action Plan:** Modify `lib/homunculus/tools/shell.rb`; add `require "timeout"`; wrap both `Open3.capture3` calls (docker_execute line 70, local_execute line 86) with `Timeout.timeout(timeout) { ... }`; remove `timeout:` kwarg.
- **Acceptance Criteria:**
  - GIVEN shell tool with sandbox enabled, WHEN command runs, THEN `Open3.capture3` is called without `timeout:` and execution is wrapped in `Timeout.timeout`
  - GIVEN shell tool with sandbox disabled, WHEN command runs, THEN same pattern applies
  - GIVEN timeout expires, WHEN Timeout.timeout raises Timeout::Error, THEN existing rescue returns `Result.fail` with `timed_out: true`
- **Technical Context:** `lib/homunculus/agent/loop.rb` line 481 pattern.
- **Agent Hint:** Builder; context: shell.rb, loop.rb (reference).

##### STORY 2: Fix sandbox.rb — Docker and local execution (≤1d)

**As a** caller of `Sandbox#execute`, **I want** commands to respect timeout **so that** execution is bounded.

- **Action Plan:** Modify `lib/homunculus/security/sandbox.rb`; add `require "timeout"`; wrap both `Open3.capture3` calls (docker_execute line 48, local_execute line 61) with `Timeout.timeout(timeout) { ... }`; remove `timeout:` kwarg.
- **Acceptance Criteria:**
  - GIVEN sandbox enabled, WHEN execute runs, THEN `Open3.capture3` called without `timeout:` and wrapped in `Timeout.timeout`
  - GIVEN sandbox disabled, WHEN execute runs, THEN same
  - GIVEN timeout expires, THEN return hash with `timed_out: true`
- **Technical Context:** Same pattern as shell.rb.
- **Agent Hint:** Builder; context: sandbox.rb.

##### STORY 3: Update shell_spec.rb stubs (≤1d)

**As a** maintainer, **I want** specs to match the new implementation **so that** tests pass and document correct behavior.

- **Action Plan:** Modify `spec/tools/shell_spec.rb`:
  - Line 264: Change `allow(Open3).to receive(:capture3).with("/bin/sh", "-c", "echo test", timeout: 30)` to `allow(Open3).to receive(:capture3).with("/bin/sh", "-c", "echo test")`; stub `Timeout.timeout` to yield and return Open3 result.
  - Lines 202–222 (timeout handling): Update stubs — `Open3.capture3` no longer receives `timeout:`; either stub `Timeout.timeout` to raise `Timeout::Error` for timeout tests, or stub `Open3.capture3` and allow `Timeout.timeout` to run normally; for "caps timeout at 120" and "defaults timeout to 30", assert that `Timeout.timeout` is called with correct value (or verify behavioral outcome).
- **Acceptance Criteria:**
  - GIVEN updated stubs, WHEN `bin/dev test spec/tools/shell_spec.rb` runs, THEN all examples pass
  - GIVEN timeout handling examples, WHEN timeout is exercised, THEN Timeout::Error is raised (via Timeout.timeout or stub) and result reflects `timed_out: true`
- **Agent Hint:** Builder; context: shell_spec.rb.

##### STORY 4: Add sandbox timeout specs (optional, 1d)

**As a** maintainer, **I want** Sandbox to have explicit timeout specs **so that** regressions are caught.

- **Action Plan:** Create `spec/security/sandbox_spec.rb` (if not exists) or add examples to existing spec; stub `Open3.capture3` and `Timeout.timeout`; verify timeout behavior and non-timeout success.
- **Acceptance Criteria:**
  - GIVEN sandbox execute with stubbed Open3, WHEN Timeout.timeout raises, THEN result has `timed_out: true`
  - GIVEN sandbox execute with stubbed Open3 returning success, WHEN no timeout, THEN result has `timed_out: false`
- **Agent Hint:** Builder; context: sandbox.rb. **Note:** No existing sandbox_spec.rb; this story can be deferred if coverage is acceptable via integration paths.

---

## 6. Test — Verification

| Layer | Check | Status |
|-------|-------|--------|
| Structural | Hierarchy intact; stories independent | ✓ |
| Self-Consistency | Decomposition stable | ✓ |
| Dependency | shell.rb, sandbox.rb, shell_spec identified | ✓ |
| Constraint | NFRs met; no behavioral change beyond fix | ✓ |
| Process Reward | Each step reduces risk | ✓ |
| Adversarial | Stale stub expectations covered in Story 3 | ✓ |

---

## 7. Execution Sequence

1. Story 1 — Fix shell.rb
2. Story 2 — Fix sandbox.rb
3. Story 3 — Update shell_spec
4. Story 4 — Optional sandbox specs (defer if timebox tight)

**Final Validation:** `bin/dev test` and `bin/dev lint`.

---

## 8. Confidence Report

| Factor | Score | Notes |
|--------|-------|-------|
| Pattern match | 95% | loop.rb pattern identical |
| Requirement clarity | 95% | Investigation report explicit |
| Decomposition stability | 90% | 4 stories, clear dependencies |
| Constraint compliance | 100% | No security/config changes |

**Overall Confidence:** 95%  
**Decision:** AUTO_PROCEED

---

## 9. Rejected Alternatives (Logged)

- **Shared helper:** 4 call sites insufficient for new abstraction.
- **Custom Process.spawn timeout:** Overkill; stdlib Timeout adequate.
- **Leaving timeout: in and catching ArgumentError:** Masks bug; incorrect API usage.
