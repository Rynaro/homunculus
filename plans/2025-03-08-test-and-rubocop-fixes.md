# Plan: Fix Test and RuboCop Failures

**Date:** 2025-03-08  
**Theme:** Fix test and RuboCop failures  
**Project:** Test and Lint remediation  
**Classification:** BUG_SPEC / CHANGE — existing codebase has style failures; tests currently pass.

---

## 1. Evidence Gathered (Read-Only)

### Test suite (`bin/dev test`)

- **Result:** All tests passed.
- **Output:** 916 examples, 0 failures. Randomized with seed 58377. Finished in ~31s.
- **Coverage:** Line coverage 79.61% (4038 / 5072).

**Conclusion:** No failing specs. No test remediation required.

### Linter (`bin/dev lint`)

- **Result:** 16 offenses detected across 7 files; 12 offenses autocorrectable.
- **Exit code:** 1.

#### Offenses by file

| File | Line | Cop | Message | Autocorrectable |
|-----|------|-----|---------|-----------------|
| bin/ollama_list_table.rb | 10 | Style/FetchEnvVar | Use ENV.fetch("INSTALLED_JSON", nil) instead of ENV["INSTALLED_JSON"] | Yes |
| bin/ollama_list_table.rb | 12 | Layout/IndentationWidth | Use 2 (not -10) spaces for indentation | Yes |
| bin/ollama_list_table.rb | 14 | Layout/ElseAlignment | Align else with if | Yes |
| bin/ollama_list_table.rb | 16 | Layout/EndAlignment | end at 16, 0 is not aligned with if at 11, 12 | Yes |
| bin/ollama_list_table.rb | 19 | Layout/EmptyLineAfterGuardClause | Add empty line after guard clause | Yes |
| bin/ollama_list_table.rb | 21 | Layout/EmptyLineAfterGuardClause | Add empty line after guard clause | Yes |
| bin/ollama_list_table.rb | 43 | Style/FormatStringToken | Prefer annotated tokens (e.g. %<foo>s) over unannotated (%s) | No (×4) |
| lib/homunculus/agent/multi_agent_manager.rb | 3 | Lint/RedundantRequireStatement | Remove unnecessary require "pathname" | Yes |
| lib/homunculus/agent/prompt.rb | 3 | Lint/RedundantRequireStatement | Remove unnecessary require "pathname" | Yes |
| lib/homunculus/memory/indexer.rb | 5 | Lint/RedundantRequireStatement | Remove unnecessary require "pathname" | Yes |
| lib/homunculus/memory/store.rb | 4 | Lint/RedundantRequireStatement | Remove unnecessary require "pathname" | Yes |
| lib/homunculus/skills/loader.rb | 3 | Lint/RedundantRequireStatement | Remove unnecessary require "pathname" | Yes |
| lib/homunculus/tools/files.rb | 3 | Lint/RedundantRequireStatement | Remove unnecessary require "pathname" | Yes |

#### Grouped by cop

- **Layout/** (IndentationWidth, ElseAlignment, EndAlignment, EmptyLineAfterGuardClause): 5 offenses, all in `bin/ollama_list_table.rb`.
- **Style/FetchEnvVar:** 1 offense, `bin/ollama_list_table.rb`.
- **Style/FormatStringToken:** 4 offenses, single line 43 in `bin/ollama_list_table.rb` (printf format string).
- **Lint/RedundantRequireStatement:** 6 offenses, one per lib file (require "pathname").

---

## 2. Scope (S)

- **Intent:** BUG_SPEC / CHANGE — fix existing RuboCop offenses; no test fixes needed.
- **In scope:** All 16 RuboCop offenses in the 7 files listed above.
- **Out of scope:** New features, coverage increases, Metrics/* refactors (per CLAUDE.md).
- **Assumptions:** `bin/dev` remains the interface for lint; no RuboCop config changes unless needed for a single cop.

---

## 3. Pattern (P)

- **Conventions:** RSpec, RuboCop with `.rubocop.yml`, `bin/dev test` and `bin/dev lint`. CLAUDE.md: never auto-correct Metrics/*; use `bin/dev lint -A` only for Style/Layout/Naming (and Lint where safe).
- **Strategy chosen:** ADAPT — apply safe auto-fixes first, then manually fix Style/FormatStringToken in `bin/ollama_list_table.rb`.

---

## 4. Explore (E)

**Strategies considered:**

1. **Auto-correct first, then manual:** Run `bin/dev lint -A` to fix 12 correctable offenses; manually fix the 4 FormatStringToken offenses in `bin/ollama_list_table.rb`. Low risk, minimal edits.
2. **By domain:** Fix all `bin/` offenses, then all `lib/` offenses. Same outcome, more steps.
3. **By cop:** Fix all RedundantRequireStatement, then Layout/Style in bin script. Same outcome.

**Chosen:** Strategy 1 — auto-correct first, then manual. Rationale: Fastest path; RedundantRequireStatement and Layout/Style/FetchEnvVar are safe; only FormatStringToken needs a targeted edit (annotated format tokens).

---

## 5. Construct (C)

### Hierarchy

**THEME:** Fix test and RuboCop failures  

**PROJECT:** Test and Lint remediation  

**FEATURE 1:** RuboCop remediation  

- **STORY 1.1:** Apply safe RuboCop auto-corrections  
  - **User story:** As a maintainer, I want the 12 autocorrectable RuboCop offenses fixed so that `bin/dev lint` passes for those cops.  
  - **Timebox:** ≤1d  
  - **Action plan:** Run `bin/dev lint -A`. Verify no Metrics/* or behavioral changes. Re-run `bin/dev test` and `bin/dev lint`.  
  - **Acceptance criteria:**  
    - GIVEN the repo with current offenses, WHEN `bin/dev lint -A` is run, THEN the 12 correctable offenses are fixed and no new offenses introduced.  
    - GIVEN the same repo, WHEN `bin/dev test` is run, THEN all 916 examples still pass.  
  - **Technical context:** Files: bin/ollama_list_table.rb, lib/homunculus/agent/multi_agent_manager.rb, lib/homunculus/agent/prompt.rb, lib/homunculus/memory/indexer.rb, lib/homunculus/memory/store.rb, lib/homunculus/skills/loader.rb, lib/homunculus/tools/files.rb.  
  - **Agent hints:** Builder; context: CLAUDE.md (lint -A only for Style/Layout/Naming); validation: `bin/dev lint` and `bin/dev test`.  

- **STORY 1.2:** Fix Style/FormatStringToken in bin/ollama_list_table.rb  
  - **User story:** As a maintainer, I want the printf on line 43 to use annotated format tokens so that Style/FormatStringToken is satisfied.  
  - **Timebox:** ≤1d  
  - **Action plan:** Replace the printf format string `"  %-10s  %-20s  %-30s  %s\n"` with annotated form, e.g. `"  %<tier>-10s  %<model>-20s  %<desc>-30s  %<status>s\n"` and pass a Hash to `printf` (or keep positional args and use named format tokens that match). Ensure output is unchanged.  
  - **Acceptance criteria:**  
    - GIVEN bin/ollama_list_table.rb, WHEN RuboCop runs, THEN no Style/FormatStringToken offenses on line 43.  
    - GIVEN the same script and sample stdin, WHEN run, THEN stdout format is unchanged (column widths and content).  
  - **Technical context:** Line 43: `printf "  %-10s  %-20s  %-30s  %s\n", tier, model, desc, status`. Ruby annotated tokens: `%<name>s` with Hash or keyword args.  
  - **Agent hints:** Builder; context: bin/ollama_list_table.rb, RuboCop Style/FormatStringToken docs; validation: `bin/dev lint`, manual run of script with sample JSON.  

**FEATURE 2:** Verification (no separate story; gates on 1.1 and 1.2)

- Final gate: `bin/dev lint` exits 0 and `bin/dev test` reports 0 failures.

---

## 6. Test (T) — Verification

- **Structural:** Single project, two stories; 1.2 depends on 1.1 only for a clean lint baseline.  
- **Constraint:** No Metrics/* auto-correct; only Style/Layout/Naming/Lint.  
- **Process:** Fix correctable first, then manual; re-run lint and test after each story.  
- **Adversarial:** If `lint -A` were to change behavior (e.g. ENV.fetch default), verify script still gets INSTALLED_JSON; FormatStringToken change must preserve printf output.

---

## 7. Assemble (A)

### Execution order

1. **Story 1.1:** Run `bin/dev lint -A`; run `bin/dev test` and `bin/dev lint` to confirm.  
2. **Story 1.2:** Edit `bin/ollama_list_table.rb` line 43 for Style/FormatStringToken; run `bin/dev lint` and sanity-check script output.

### Confidence

| Factor | Score | Notes |
|--------|-------|--------|
| Pattern match | 95% | Standard lint remediation; project conventions clear. |
| Requirement clarity | 95% | All offenses and files enumerated. |
| Decomposition stability | 90% | Two stories; only FormatStringToken is non-trivial. |
| Constraint compliance | 100% | No Metrics/* auto-correct; bin/dev only. |
| **Overall** | **95%** | AUTO_PROCEED — deliver for coder execution. |

### Deliverables

- This plan: `plans/2025-03-08-test-and-rubocop-fixes.md`
- Agent handoff: `plans/2025-03-08-test-and-rubocop-fixes.yaml`

---

*SPECTRA plan — READ-ONLY. No code edits by planner.*
