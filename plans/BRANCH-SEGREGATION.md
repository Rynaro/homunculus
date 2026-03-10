# Branch Segregation — SPECTRA Plan Alignment

Work from the current working tree is segregated into three branches aligned with SPECTRA plans.

## Branch 1: `feat/adaptive-web-phase1`

**Plan:** `2026-03-08-adaptive-web-interaction.yaml` (Phase 1)

**Scope:** HTTP path tightening, classification taxonomy, strategy evaluator stub.

| Files | Change |
|-------|--------|
| `lib/homunculus/tools/web_classification.rb` | NEW — failure taxonomy |
| `lib/homunculus/tools/web_strategy.rb` | NEW — strategy evaluator |
| `config/boot.rb` | require web_strategy, web_research |
| `lib/homunculus/tools/web.rb` | classification integration |
| `lib/homunculus/tools/web_extract.rb` | classification integration |
| `spec/tools/web_spec.rb` | classification specs |
| `spec/tools/web_extract_spec.rb` | classification specs |
| `plans/2026-03-08-adaptive-web-interaction.yaml` | plan artifact |

**Base:** `main`

---

## Branch 2: `fix/web-tool-selection`

**Plan:** `2026-03-09-web-tool-selection-fix`

**Scope:** Tool descriptions, prompt strategy, UA fix, actionable classification messages.

| Files | Change |
|-------|--------|
| `lib/homunculus/agent/prompt.rb` | web_strategy guidance section |
| `lib/homunculus/tools/web.rb` | descriptions, UA, classification_message |
| `lib/homunculus/tools/web_research.rb` | description rewrite |
| `lib/homunculus/tools/web_extract.rb` | description rewrite |
| `lib/homunculus/sag/retriever.rb` | UA alignment |
| `lib/homunculus/config.rb` | WebConfig, tools.web |
| `config/default.toml` | [tools.web] user_agent_override |
| `spec/agent/prompt_spec.rb` | prompt specs |
| `spec/tools/web_research_spec.rb` | specs |
| `spec/sag/retriever_spec.rb` | specs |
| `spec/config_spec.rb` | config specs |
| `plans/2026-03-09-web-tool-selection-fix.md` | plan artifact |
| `plans/2026-03-09-web-tool-selection-fix.yaml` | plan artifact |

**Base:** `feat/adaptive-web-phase1`

---

## Branch 3: `feat/searxng-bootstrap`

**Plan:** `2026-03-09-searxng-dependency-bootstrap`

**Scope:** SearXNG Docker service, CLI integration, reachability gate.

| Files | Change |
|-------|--------|
| `docker-compose.yml` | searxng service, profile |
| `docker-compose.dev.yml` | searxng service |
| `config/searxng/settings.yml` | NEW — minimal config |
| `bin/assistant` | --with-searxng, doctor, obliterate |
| `config/default.toml` | [sag] section |
| `lib/homunculus/config.rb` | SEARXNG_URL override |
| `lib/homunculus/interfaces/sag_reachability.rb` | NEW — reachability check |
| `lib/homunculus/interfaces/cli.rb` | SAGReachability, register_sag_tool |
| `lib/homunculus/interfaces/tui.rb` | SAGReachability, register_sag_tool |
| `lib/homunculus/interfaces/telegram.rb` | SAGReachability, register_sag_tool |
| `.env.example` | SEARXNG_URL |
| `CLAUDE.md` | --with-searxng, SearXNG mention |
| `plans/2026-03-09-searxng-dependency-bootstrap.md` | plan artifact |
| `plans/2026-03-09-searxng-dependency-bootstrap.yaml` | plan artifact |

**Base:** `main`

---

## Unassigned / Collateral

- `lib/homunculus/agent/loop.rb`, `spec/agent/loop_spec.rb` — review and assign if needed
- `lib/homunculus/interfaces/tui/activity_indicator.rb`, `input_buffer.rb`, `message_renderer.rb` — TUI refinements
- `spec/interfaces/*`, `spec/spec_helper.rb` — interface spec updates

---

## Merge Order

1. Merge `feat/adaptive-web-phase1` → `main`
2. Merge `fix/web-tool-selection` → `main` (resolve any conflicts with config/prompt)
3. Merge `feat/searxng-bootstrap` → `main` (resolve config default.toml, config.rb, interfaces)
