# Plan: Fix Security Audit (Gitleaks) CI Failure

**Date:** 2026-03-08  
**Theme:** CI reliability  
**Project:** Security Audit job  
**Classification:** BUG_SPEC — CI step fails due to shallow clone; no actual secret leak.

---

## 1. CLARIFY / Evidence (Read-Only)

### Observed failure

- **Job:** Security Audit (`.github/workflows/ci.yml`, job `security`)
- **Trigger:** Pull request (e.g. PR #19 merge ref `800a0e1`)
- **Exit code:** 1 (reported as "ERROR: Unexpected exit code [1]")

### Relevant log excerpts

```text
gitleaks cmd: gitleaks detect --redact -v --exit-code=2 --report-format=sarif --report-path=results.sarif --log-level=debug --log-opts=--no-merges --first-parent c2a7ca8245b5696616996bb6f9dc63f91f3eaf6e^..b24a131961969b7d678e332638d650a1b01a2230
[git] fatal: ambiguous argument 'c2a7ca8245b5696616996bb6f9dc63f91f3eaf6e^..b24a131961969b7d678e332638d650a1b01a2230': unknown revision or path not in the working tree.
failed to scan Git repository
```

- **Checkout:** `actions/checkout@v4` with no `fetch-depth` override → default is shallow (e.g. `fetch-depth: 1` for the merge commit).
- **Gitleaks-action:** Runs `gitleaks detect` with a commit range `base^..head` to scan only PR-introduced commits. The **base** commit is not in the repo when the clone is shallow, so `git log` fails with "unknown revision".

### Root cause

Shallow checkout does not include the PR base commit. Gitleaks-action requires that range to exist for its `git log -p base^..head` scan. Hence the failure is **environment/setup**, not a real secret finding.

### Out of scope

- Changing gitleaks rules or adding `.gitleaks.toml` (not required for this fix).
- Changing other jobs’ checkout depth unless needed for consistency.

---

## 2. Scope (S)

| In scope | Out of scope |
|----------|--------------|
| Fix Security Audit job so gitleaks can resolve the commit range | Bundler-audit step (already passing) |
| Single change: ensure checkout has enough history for gitleaks | Other workflow jobs |
| Document rationale in plan | Modifying gitleaks-action or running gitleaks manually |

**Stakeholders:** CI consumers; no approval chain beyond normal PR review.

**Complexity:** 4/12 — single-file, single-step config change.

---

## 3. Pattern (P)

- **Existing:** `.github/workflows/ci.yml` — Security job uses `actions/checkout@v4` with no `with:` args.
- **Industry fix:** Use full (or sufficient) history for the job that runs gitleaks so the PR base commit exists. Standard approach: set **`fetch-depth: 0`** on checkout for that job (see [gitleaks/gitleaks-action#71](https://github.com/gitleaks/gitleaks-action/pull/71), [gitleaks/gitleaks-action#154](https://github.com/gitleaks/gitleaks-action/issues/154)).
- **Strategy:** USE_TEMPLATE — apply the documented fix (checkout with `fetch-depth: 0` in the Security Audit job only).

---

## 4. Explore (E)

| Option | Description | Pros | Cons |
|--------|-------------|------|------|
| **A. fetch-depth: 0 in Security job** | Add `with: fetch-depth: 0` to the Checkout step of the `security` job. | Minimal change, well-documented fix, no new dependencies. | Slightly larger clone for that job only. |
| B. Deepen clone in a separate step | Run `git fetch --unshallow` after checkout. | Same effective result. | Extra step and more moving parts. |
| C. Disable range scan | Configure gitleaks to scan only working tree. | Avoids need for history. | Diverges from action’s intended use; may miss history-based leaks. |

**Chosen:** A — add `fetch-depth: 0` to the Security job’s Checkout step. Rationale: One clear, standard change; matches gitleaks-action maintainers’ recommendation.

---

## 5. Construct (C)

### Story (single story sufficient)

- **As a** maintainer  
- **I want** the Security Audit job to succeed on pull requests  
- **So that** gitleaks can scan the PR commit range without "unknown revision" errors.

**Timebox:** 1d (trivial change).

### Task (implementation step)

1. **Modify** `.github/workflows/ci.yml`:
   - In the **Security Audit** job (`security`), in the **Checkout** step (`actions/checkout@v4`), add a `with:` block (if missing) and set **`fetch-depth: 0`** so the clone includes full history and the PR base commit is available for gitleaks’ range scan.

**Acceptance criteria:**

- GIVEN a pull request targeting `main`  
  WHEN the Security Audit job runs  
  THEN the Checkout step uses `fetch-depth: 0`  
  AND the gitleaks step runs without "unknown revision" / "fatal: ambiguous argument" errors  
  AND the job succeeds when no secrets are present (or fails with exit code 2 only when gitleaks finds leaks).

**Technical context:**

- File: `.github/workflows/ci.yml`
- Job: `security` (name: "Security Audit")
- Step to change: first step, "Checkout", `uses: actions/checkout@v4`
- Exact change: add `with: fetch-depth: 0` to that step.

**Verification:**

- Push a branch and open a PR (or re-run the failed Security Audit job after the change). Confirm the job completes without the git revision error.

---

## 6. Test (T) — Verification layers

| Layer | Check | Result |
|-------|--------|--------|
| Structural | Single task, single file, clear owner | OK |
| Constraint | No secrets in repo; no change to audit log or security logic | OK |
| Adversarial | Could we break other jobs? No — only `security` job checkout is changed. | OK |

---

## 7. Assemble — Deliverables

- **Plan artifact:** This file (`plans/2026-03-08-security-audit-gitleaks-fix.md`).
- **Agent handoff:** `plans/2026-03-08-security-audit-gitleaks-fix.yaml` for the coder agent.
- **Confidence:** 95% — root cause and fix are standard and documented.

---

## 8. Rejected alternatives

- **Full repo scan without range:** Would avoid shallow-clone issue but changes gitleaks behavior and is not the recommended fix.
- **Git fetch --unshallow in a separate step:** Works but is redundant when `fetch-depth: 0` achieves the same with one config change.
