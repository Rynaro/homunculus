# bin/ollama — Model Store & Management CLI

## Context

Following the [bin/assistant](dd40cfe2-7c50-4874-a664-1940bd68de9e) work, users need an easy way to see which Ollama models Homunculus expects (from `config/models.toml`), which are installed, and to install or remove models. This is a **standalone** utility (`bin/ollama`), not an assistant subcommand.

---

## SPECTRA Summary

- **Intent:** REQUEST — clear goal, specs derived from user need.
- **Complexity:** 5/12 — Standard.
- **Pattern:** ADAPT from `bin/assistant` (bash dispatch, colors, Docker-awareness).
- **Approach:** Bash script + inline Ruby for TOML parsing; curl for Ollama API.

---

## Command Surface

| Command | Description |
|--------|-------------|
| `bin/ollama` | Default: show model store (same as list) |
| `bin/ollama list` | Fleet models with install status table |
| `bin/ollama status` | Ollama health + fleet summary |
| `bin/ollama pull <tier>` | Pull a specific tier's model |
| `bin/ollama pull --all` | Pull all missing fleet models |
| `bin/ollama remove <tier>` | Remove a tier's model (with confirmation) |
| `bin/ollama help` | Command reference |

---

## Stories (Execution Order)

### Story 1: Model Fleet Discovery
- **Timebox:** 1d
- Create `bin/ollama` with bash dispatch and color helpers (from `bin/assistant`).
- Inline Ruby: parse `config/models.toml` for `[tiers.*]` where `provider = "ollama"`, plus embedding model from `config/default.toml`; emit JSON.
- `cmd_list`: call parser, query Ollama API (`GET /api/tags`), cross-reference, display table (Tier, Model, Description, Status, Size).
- Ollama connectivity: try host `127.0.0.1:11434`, fallback to `docker exec homunculus-ollama` if needed.
- **Acceptance:** `bin/ollama list` shows fleet-only models with Installed/Missing; clear error if Ollama unreachable.

### Story 4: Help & Status
- **Timebox:** 0.5d
- `cmd_help`: grouped command reference.
- `cmd_status`: Ollama reachability, fleet summary (installed vs expected).
- Default (no args) = list view.
- **Acceptance:** `bin/ollama`, `bin/ollama help`, `bin/ollama status` work as described.

### Story 2: Model Installation (Pull)
- **Timebox:** 1d
- `cmd_pull <tier>` and `cmd_pull --all`; progress passthrough from `ollama pull`.
- Docker-aware: if using Docker Ollama, exec into container for pull.
- **Acceptance:** `bin/ollama pull whisper` pulls that tier's model; `bin/ollama pull --all` pulls all missing; invalid tier shows error with valid tiers.

### Story 3: Model Removal
- **Timebox:** 0.5d
- `cmd_remove <tier>` with confirmation (model name + size).
- Docker-aware removal.
- **Acceptance:** Remove only after confirm; "not installed" message when applicable.

---

## Files Changed

| Action | File |
|--------|------|
| NEW | `bin/ollama` |
| EDIT | `README.md` — add bin/ollama section |
| EDIT | `CLAUDE.md` — add bin/ollama to Commands |

---

## Sample Output (list)

```
🏪 Homunculus Model Store
══════════════════════════════════════════════════════════════════

  Tier        Model                 Description                    Status
  ──────────  ────────────────────  ─────────────────────────────  ──────────
  whisper     qwen3:4b              Fast triage, classification    ✓ Installed (2.3 GB)
  workhorse   qwen3:14b             General daily tasks, chat      ✗ Missing
  coder       qwen2.5-coder:14b     Code generation, debugging     ✓ Installed (8.9 GB)
  thinker     deepseek-r1:14b       Deep reasoning, analysis       ✗ Missing
  embedding   nomic-embed-text      Memory embeddings              ✓ Installed (274 MB)

  Fleet: 3/5 installed · 11.5 GB used

  Pull missing: bin/ollama pull --all
```

---

## Technical Notes

- **TOML parsing:** Use Ruby + `toml-rb` (already in Gemfile). Invoke via `ruby -e` or small script; emit JSON for bash.
- **Ollama API:** `GET http://127.0.0.1:11434/api/tags` returns list of installed models with names and sizes.
- **Docker fallback:** If host curl to 11434 fails, check `docker ps` for `homunculus-ollama` and use `docker exec homunculus-ollama ollama list` / `ollama pull` / `ollama rm`.
