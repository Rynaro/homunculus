---
name: failure-recovery
---

# Failure Recovery Skill

Structured failure classification, targeted debugging, and escalation protocols. Loaded when the Verify phase produces failures.

---

## Critical Rule: Evidence Gate

**Before attempting ANY fix, you MUST have concrete evidence.**

Acceptable evidence:
- Test failure output with assertion message and file:line
- Lint error with rule name, file:line, and violation description
- Build error with compiler/bundler output
- Runtime error with full stack trace
- Type error with expected vs actual types

**If you have NONE of these → ESCALATE immediately.**
Do not hypothesize fixes without evidence. This is the single most important rule in failure recovery.

---

## Failure Classification Taxonomy

Classify every failure into exactly ONE primary category:

| Category | Signal | Example |
|----------|--------|---------|
| **TEST_ASSERTION** | Expected vs actual mismatch in test output | `Expected 5, got 3` |
| **REGRESSION** | Previously passing test now fails | `TestWidgetCreate failed (was passing)` |
| **BUILD_ERROR** | Compilation, bundling, or dependency resolution failure | `Cannot find module 'widget'` |
| **TYPE_ERROR** | Type mismatch caught by compiler or runtime | `No implicit conversion of String to Integer` |
| **LINT_VIOLATION** | Style or complexity rule violation | `Rubocop: Method has too many lines` |
| **RUNTIME_ERROR** | Exception during execution | `NoMethodError: undefined method 'foo'` |
| **LOGIC_ERROR** | Code runs without error but produces wrong result | Test passes but behavior is incorrect |
| **INTEGRATION_ERROR** | Failure at boundary between components | API contract mismatch, missing migration |
| **ENVIRONMENT_ERROR** | Missing dependency, config, or service | Database not running, env var missing |

---

## Debugging Protocol

### Step 1: Isolate

For each failure:
```
1. Record the EXACT error output (copy-paste, do not paraphrase)
2. Identify the file:line where the error manifests
3. Identify the file:line where the error ORIGINATES (may be different)
4. Classify using taxonomy above
```

### Step 2: Root Cause Analysis

**Work backward from the error, not forward from the code.**

```
For TEST_ASSERTION:
  → What value was expected? What was produced?
  → Trace the produced value back to its source
  → Where does the actual logic diverge from expected?

For REGRESSION:
  → What changed since the test last passed?
  → Diff the changed files against the last known good state
  → Is the regression in the code change or in test setup?

For BUILD_ERROR:
  → Is it a missing import/require?
  → Is it a syntax error?
  → Is it a dependency version conflict?

For TYPE_ERROR:
  → What type was expected at this point?
  → Where was the wrong type introduced?
  → Is this a nil/null propagation issue?

For RUNTIME_ERROR:
  → Read the full stack trace bottom-to-top
  → Identify the first frame in YOUR code (not library code)
  → What assumption was violated at that point?
```

### Step 3: Generate Fix Hypothesis

For each root cause, generate ONE targeted hypothesis:
```
- What: [specific change to make]
- Where: [exact file:line]
- Why: [how this addresses the root cause]
- Confidence: HIGH / MED / LOW
- Risk: [what could this fix break?]
```

**Rules:**
- ONE hypothesis per failure. Do not batch fixes.
- The fix must be MINIMAL. Change as few lines as possible.
- If the fix requires changing more than the original implementation scope, this is a signal to re-plan, not to expand the fix.

---

## Targeted Fix Strategy

### The Overcorrection Prevention Protocol

LLMs have a strong tendency to overcorrect — rewriting entire functions when a single line needs to change. Guard against this:

```
✅ Good fix: Change line 42 from `user.name` to `user.full_name`
❌ Bad fix: Rewrite the entire method "for clarity" while fixing line 42
```

**Rules:**
1. Fix ONLY the specific line(s) identified in root cause analysis
2. Do NOT refactor surrounding code during a fix
3. Do NOT add "improvements" while fixing a bug
4. Do NOT modify test expectations to match broken behavior
5. If the fix tempts you to restructure, LOG the restructuring as a Delta suggestion instead

### Targeted Test Execution

After applying a fix:
```
1. Run ONLY the single failing test first
2. If it passes → run the broader test suite
3. If a NEW test fails → classify it separately (is it related to the fix?)
4. If the SAME test still fails → this counts as a retry attempt
```

### Block-by-Block Verification (for complex changes)

When a fix touches multiple interconnected parts:
```
1. Identify the execution path through the changed code
2. Add temporary logging/assertions at block boundaries
3. Verify intermediate state at each boundary:
   - Input to block: correct?
   - Output from block: correct?
   - State mutations: as expected?
4. The first block with incorrect output is the actual failure point
5. Remove temporary instrumentation after fix is confirmed
```

---

## Retry Decision Matrix

| Attempt | Condition | Action | Documentation Required |
|---------|-----------|--------|-----------------------|
| **1st failure** | HIGH or MED confidence | Apply targeted fix | Log: error, hypothesis, fix applied |
| **1st failure** | LOW confidence | ESCALATE | Log: error, all hypotheses considered |
| **2nd failure** | Same category as 1st | **MUST use a different approach** | Log: why first approach failed, new hypothesis |
| **2nd failure** | Different category | Treat as 1st failure of new category | Log: new error details |
| **3rd failure** | Same category as previous | **ESCALATE** | Full summary of all attempts |
| **Any failure** | No concrete artifacts | **ESCALATE immediately** | Document what was attempted |
| **Any failure** | Fix would exceed original scope | **ESCALATE** | Document scope expansion needed |

### What "Different Approach" Means

When the same category fails twice, you MUST change strategy:

```
If TEST_ASSERTION failed twice:
  → First fix addressed the symptom. Step back to the logic.
  → Re-read the test to understand INTENT, not just assertion.
  → Consider: is the test correct? Is the spec ambiguous?

If BUILD_ERROR failed twice:
  → First fix was a patch. Address the structural issue.
  → Check if the dependency graph is correct.
  → Consider: is the architecture approach viable?

If REGRESSION failed twice:
  → The change approach may be fundamentally incompatible.
  → Consider reverting and using a different strategy from the Plan.
  → This may indicate the selected strategy was wrong.
```

---

## Loop Detection

### Repetition Signals

You are in a loop if:
- You are making the same type of change for the 3rd time
- The error message is identical to a previous iteration
- You are undoing a change you made earlier in this session
- You are alternating between two states (fix A breaks B, fix B breaks A)

### Loop Breaking Protocol

```
1. STOP immediately
2. Summarize the loop pattern:
   - "I have alternated between [state A] and [state B] for [N] iterations"
   - "Each fix for [error X] introduces [error Y]"
3. Assess: Is this a sign that the PLAN is wrong (not just the implementation)?
4. Options:
   a. Return to Plan phase with new information
   b. Try the runner-up strategy from the Plan
   c. ESCALATE with loop analysis
```

---

## Escalation Format

When escalating, provide this structured output:

```markdown
## 🚨 Escalation: [task description]

### Attempts Summary
| # | Approach | Result | Evidence |
|---|----------|--------|----------|
| 1 | [what was tried] | [what happened] | [error ref] |
| 2 | [what was tried] | [what happened] | [error ref] |

### Evidence Collected
[Paste actual error output, test results, stack traces]

### Root Cause Assessment
- Primary hypothesis: [description] (Confidence: LOW/MED)
- Alternative hypotheses considered: [list]
- Why I cannot resolve this: [specific reason]

### Recommended Human Actions
1. [Most likely to resolve the issue]
2. [Alternative approach]
3. [What to investigate]

### Context for Resumption
- Current branch/state: [description]
- Files modified so far: [list]
- Tests passing: [count] / Tests failing: [count]
- How to reproduce: [command]
```

---

## Common Failure Patterns in Brownfield Code

### Pattern: Fixture/Factory Mismatch
**Signal**: Test fails because test data doesn't match current schema
**Fix**: Update factory/fixture, NOT the production code
**Trap**: Do NOT modify the migration or schema to match outdated test data

### Pattern: Hidden Side Effect
**Signal**: Test passes in isolation, fails in suite
**Fix**: Look for shared state (class variables, database state, external services)
**Trap**: Do NOT add `skip` or change test ordering

### Pattern: Convention Violation
**Signal**: Framework magic doesn't fire (callbacks, validations, routing)
**Fix**: Check naming conventions, file locations, inheritance chains
**Trap**: Do NOT bypass the framework with manual wiring

### Pattern: Nil Propagation
**Signal**: NoMethodError on nil:NilClass (Ruby) or TypeError: Cannot read property of undefined (JS)
**Fix**: Trace the nil backward to its source. Usually a missing association or query returning empty.
**Trap**: Do NOT add nil checks everywhere — fix the source

### Pattern: Stale Dependencies
**Signal**: Method exists in source but "not found" at runtime
**Fix**: Check autoloading, require statements, bundle/package lock freshness
**Trap**: Do NOT duplicate the method in a new location

---

*Failure Recovery Skill — evidence-gated, targeted, loop-aware*

