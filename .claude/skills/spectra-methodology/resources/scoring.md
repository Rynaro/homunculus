# SPECTRA Scoring & Validation

All rubrics, matrices, and validation criteria. Load on-demand during Explore, Test, Refine, and Assemble phases.

---

## Complexity Scoring (Scope Phase)

Score each dimension 1-3, sum for total (4-12):

| Dimension | 1 (Low) | 2 (Medium) | 3 (High) |
|-----------|---------|------------|----------|
| **Scope** | Single feature | Multi-feature | Multi-project |
| **Ambiguity** | Clear requirements | Some gaps | Vague/conflicting |
| **Dependencies** | Isolated | 2-3 systems | Cross-domain |
| **Risk** | Low impact | User-facing | Critical path |

**Thresholds:**
- 4-6: Standard processing
- 7-9: Extended thinking (2x tokens)
- 10-12: Human collaboration recommended

---

## Pattern Match Strategy (Pattern Phase)

| Match Confidence | Strategy |
|------------------|----------|
| **≥85%** | USE_TEMPLATE — apply pattern directly |
| **60-84%** | ADAPT — pattern as starting point |
| **<60%** | GENERATE — new, with patterns as context |

**MMR Selection:** Retrieve 15 candidates, select 5 maximizing `similarity - 0.3 × redundancy`

---

## Hypothesis Quick-Score (Explore Phase — Triage)

Score each dimension 1-3, sum for total (5-15). Use this for initial triage before the full rubric:

| Dimension | 1 (Poor) | 2 (Acceptable) | 3 (Optimal) |
|-----------|----------|----------------|-------------|
| **Feasibility** | High uncertainty | Some unknowns | Clear path |
| **Value Alignment** | Partial value | Good value | Direct value |
| **Risk Profile** | High blast radius | Moderate | Contained |
| **Pattern Fit** | Ignores patterns | Partial use | Full leverage |
| **Timebox Fit** | Likely exceeds | Tight | Comfortable |

**Rules:**
- Minimum 3 hypotheses (no strawmen)
- At least one conservative (low-risk)
- At least one pattern-leveraging
- At least one innovative
- Expand top 2 before selection

---

## Hypothesis Full Rubric (Explore Phase — Selection)

Score each dimension 1-10. Compute weighted total. Apply to top 2-3 candidates from triage.

| Dimension | Weight | 10 = Optimal | 1 = Unacceptable | Guiding Question |
|-----------|--------|-------------|-------------------|------------------|
| **Alignment** | 25% | Matches requirements exactly, no assumptions | Ignores key requirements | Does it solve the stated goal? |
| **Correctness & Feasibility** | 20% | Technically sound, edge cases covered | Breaks on obvious inputs | Will this actually work in the codebase? |
| **Maintainability** | 15% | Clean, extensible, follows conventions | Spaghetti, coupling, magic | Will future developers thank us? |
| **Performance & Scalability** | 15% | Efficient, handles growth | O(n²) in hot paths | Real-world load? |
| **Simplicity** | 10% | Minimal code, obvious abstractions | Over-engineered | "This is the obvious way" feeling? |
| **Risk & Robustness** | 10% | Low risk, failure modes handled | Security holes, race conditions | What could go wrong? |
| **Innovation** | 5% | Creative but grounded | Boring or reckless | Better than the obvious solution? |

**Score interpretation:**
- ≥85 weighted total → **Elite.** Strong confidence in selection.
- 70–84 → **Solid.** Proceed with noted concerns.
- <70 → **Weak.** Reconsider or re-observe.

**Anti-strawman rule:** If all hypotheses score within 5% of each other → insufficient differentiation. Re-observe from different angles.

---

## INVEST Validation (Construct Phase)

Every story must pass all six criteria before inclusion:

| Criterion | Question | Fail Action |
|-----------|----------|-------------|
| **I**ndependent | Can deliver without other stories? | Split dependencies |
| **N**egotiable | Details discussable? | Add flexibility |
| **V**aluable | Delivers user/business value? | Reframe or drop |
| **E**stimable | Timebox confident? | Add spike or split |
| **S**mall | Within ≤8d threshold? | Decompose further |
| **T**estable | Clear acceptance criteria? | Add GIVEN/WHEN/THEN |

---

## Timebox System

| Timebox | Meaning | Estimation Confidence |
|---------|---------|----------------------|
| 1d | Single focused day | HIGH |
| ≤2d | Up to 2 days | HIGH |
| ≤3d | Up to 3 days | MEDIUM |
| ≤5d | Up to 5 days | MEDIUM |
| ≤8d | Threshold | LOW |
| >8d | — | **MUST DECOMPOSE** |

Never use story points. Timeboxes are wall-clock commitments.

---

## Self-Consistency Check (Test Phase)

Generate 3 alternative decompositions of the same feature. Measure story overlap:

| Overlap | Interpretation | Action |
|---------|----------------|--------|
| ≥70% | HIGH confidence — decomposition stable | Proceed |
| 50–69% | MEDIUM — multiple valid structures | Document rationale for chosen structure |
| <50% | LOW — fundamentally ambiguous | Re-enter Explore or request clarification |

---

## 6-Layer Verification Checklist (Test Phase)

| # | Layer | Pass Criteria |
|---|-------|--------------|
| 1 | **Structural** | Hierarchy intact, no orphaned tasks, stories independent |
| 2 | **Self-Consistency** | ≥70% overlap across 3 alternative decompositions |
| 3 | **Dependency** | All affected files identified, call sites covered, migration paths defined |
| 4 | **Constraint** | NFRs met, timeboxes realistic, security/compliance addressed |
| 5 | **Process Reward** | Each step reduces risk or increases clarity; ordering is optimal |
| 6 | **Adversarial** | "What could go wrong?" answered; skeptical reviewer's challenges addressed |

**Gate:** All 6 pass → Assemble | 1-2 minor gaps → Refine (1 cycle) | Major gaps → Refine (up to 3) | Fundamental issues → back to Explore

---

## Self-Critique Dimensions (Refine Phase)

Score 1-5, target all ≥4:

| Dimension | Question | 5 = Excellent | 1 = Unacceptable |
|-----------|----------|--------------|-------------------|
| **Clarity** | Could a junior dev understand this? | Crystal clear, no jargon | Ambiguous, assumes deep context |
| **Completeness** | All edge cases addressed? | Comprehensive, nothing missing | Obvious gaps |
| **Actionability** | Could an agent execute without questions? | Self-contained with all context | Requires clarification to proceed |
| **Efficiency** | Simplest path to goal? | Minimal, no waste | Over-engineered or roundabout |
| **Testability** | Acceptance criteria unambiguous? | GIVEN/WHEN/THEN, measurable | Vague "should work" |

**Cycle targets:**
1. Fix major structural issues → all ≥3
2. Polish clarity and completeness → all ≥4
3. Final refinement → all ≥4 OR diminishing returns

**Max 3 cycles — escalate if gate not met.**

---

## Confidence Calculation (Assemble Phase)

| Factor | Weight | Score (0-3) | What It Measures |
|--------|--------|-------------|------------------|
| Pattern Match | 25% | How well prior patterns apply | Reuse vs. novelty |
| Requirement Clarity | 25% | Input completeness | Ambiguity risk |
| Decomposition Stability | 25% | Self-consistency overlap | Structural confidence |
| Constraint Compliance | 25% | Verification pass rate | Rule adherence |

**Formula:** `Confidence = (sum of weighted scores / max possible) × 100`

**Gating decisions:**

| Confidence | Decision | Action |
|------------|----------|--------|
| ≥85% | AUTO_PROCEED | Deliver, agents execute |
| 70-84% | VALIDATE | Deliver with flags for human review |
| 50-69% | COLLABORATE | Halt, request clarifications |
| <50% | ESCALATE | Hand to human with gap analysis |

---

## Scoring Calibration Protocol

Before using rubrics in a new context (new team, new model, new domain), calibrate with anchor plans:

| Reference | Quality Level | Expected Score Range |
|-----------|--------------|---------------------|
| **Anchor-Low** | Missing acceptance criteria, vague stories, no dependency analysis | 25–40 weighted total |
| **Anchor-Mid** | Competent but minor issues (one ambiguous criterion, coverage unspecified) | 60–75 weighted total |
| **Anchor-High** | Exemplary (all criteria clear, edge cases addressed, clean dependencies) | 85–95 weighted total |

**Protocol:**
1. Score all three anchors using the hypothesis rubric above.
2. Compare your scores to expected ranges.
3. If scores diverge by >10 points → recalibrate dimension interpretation.
4. For LLM-as-Judge: include all three anchors with pre-assigned scores as few-shot examples.

**Inter-rater target:** Krippendorff's α ≥ 0.67 across evaluators after calibration. Plans in `examples/` can serve as calibration anchors.

See [THEORY.md](../research/THEORY.md#8-scoring-calibration-protocol) for the psychometric foundation.

---

## Failure Taxonomy (Test Phase — Adversarial Layer)

Check plans against these failure modes during the Adversarial verification layer:

| Failure Mode | Diagnostic Signal | Remedy |
|-------------|-------------------|--------|
| **Under-specification** | Executor asks clarifying questions | Add acceptance criteria; return to Construct |
| **Over-specification** | Valid implementations blocked by rigid constraints | ADaPT: loosen constraints, collapse steps |
| **Dependency Blindness** | Build breaks after "complete" execution | Strengthen Dependency layer; add structural context |
| **Assumption Drift** | Steps invalidated by earlier discoveries | Full replan from Scope with new constraints |
| **Scope Creep** | Tangential stories; token budget exhausted | Enforce boundary table; drop out-of-scope items |
| **Premature Optimization** | Complex architecture for simple problem | Check complexity score; apply ADaPT (≤5 → simplify) |
| **Stale Context** | File contents changed since planning | Refresh structural context; re-run Dependency check |
| **Oscillating Refinement** | Dimension score returns to prior value across cycles | Halt immediately; escalate with conflict identified |

---

*SPECTRA v4.2.0 — Scoring & Validation*