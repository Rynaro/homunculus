# TUI Experience Augmentation

## Context

The current TUI (`lib/homunculus/interfaces/tui.rb`, 577 lines) is a custom full-screen ANSI-based interface using raw `$stdin.read_nonblock(1)` input and positioned rendering via escape codes. While functional, it has multiple UX issues that make interaction cumbersome: broken scrolling during streaming, no loading feedback, no cursor navigation in input, duplicate UI elements, and limited model tier visibility.

---

## SPECTRA Summary

- **Intent:** CHANGE — Modify existing TUI to fix UX bugs and add interactive features.
- **Complexity:** 7/12 — Extended. 8 distinct augmentations touching rendering, input, streaming, and status subsystems.
- **Pattern:** ADAPT — Existing region-based architecture (header / chat / status / input) is a solid skeleton. Extend each region; introduce internal state machines for input and activity indicators.
- **Approach:** Incremental enhancement of the custom ANSI TUI. No new gem dependencies. Preserve the alternate-screen, region-redraw rendering strategy. Add a lightweight `InputBuffer` abstraction for cursor-aware editing and a `Spinner` module for activity indication.

### Rejected Alternatives

| Alternative | Why Rejected |
|------------|--------------|
| Switch to `tty-reader` / `tty-cursor` gems | Adds external dependency; the custom approach gives full control over escape handling and is already well-tested. Migration cost exceeds benefit. |
| Full rewrite with `curses` / `ncurses` | Heavyweight; requires native extension. Portability concerns in Docker. Overkill for a single-panel chat UI. |
| Adopt Textual (Python) via subprocess | Cross-language boundary adds latency and complexity. Defeats the purpose of a Ruby-native agent. |

---

## Stories (Execution Order)

### Story 1: Input Buffer with Cursor Navigation

**As a** user, **I want** to navigate within my input text using arrow keys **so that** I can correct typos without backspacing to the error.

- **Timebox:** 1.5d
- **Risk:** P1 — Degraded input experience is the most impactful daily friction.

**Action Plan:**

1. **Create** `InputBuffer` internal class (inside `tui.rb` or extracted to `lib/homunculus/interfaces/tui/input_buffer.rb`) with:
   - `@buf` (String), `@cursor` (Integer position within buf)
   - `insert(char)` — inserts at cursor, advances cursor
   - `backspace` — deletes char before cursor
   - `delete` — deletes char at cursor (Del key)
   - `move_left` / `move_right` — moves cursor ±1
   - `move_home` / `move_end` — Ctrl+A / Ctrl+E (jump to start/end)
   - `move_word_left` / `move_word_right` — Ctrl+Left / Ctrl+Right
   - `to_s` — returns full buffer
   - `clear` — resets buffer and cursor
2. **Modify** `read_line` to use `InputBuffer` instead of raw `buf` string.
3. **Modify** `consume_escape_sequence` to route arrow Left (`[D`) / Right (`[C`) to `InputBuffer` instead of discarding.
4. **Modify** `render_input_line` to show cursor position (e.g., `\e[?25h` show cursor + `\e[{col}G` position to `@cursor` offset after prompt).
5. **Add** Ctrl+A (home), Ctrl+E (end), Ctrl+W (delete word backward) bindings in `read_line`.
6. **Test** `InputBuffer` unit specs: insert, delete, cursor movement, boundary conditions.

**Acceptance Criteria:**

- GIVEN a user typing in the TUI input, WHEN they press Left/Right arrows, THEN the cursor moves within the text and new characters insert at the cursor position.
- GIVEN a user at position 5 in a 10-char input, WHEN they press Backspace, THEN only the character before the cursor is deleted.
- GIVEN a user pressing Ctrl+A, THEN the cursor moves to position 0.

**Technical Context:**

- Escape sequences: `\e[C` (Right), `\e[D` (Left), `\e[H` (Home), `\e[F` (End), `\e[1;5C` (Ctrl+Right), `\e[1;5D` (Ctrl+Left)
- The visible cursor must be shown during input mode (`\e[?25h`) and hidden during rendering (`\e[?25l`)
- Files: `lib/homunculus/interfaces/tui.rb` (read_line, render_input_line, consume_escape_sequence)

**Agent Hints:**

- Class: Builder (speed)
- Context files: `lib/homunculus/interfaces/tui.rb:556-612` (input handling), `spec/interfaces/tui_spec.rb`
- Gate: All existing specs pass + new InputBuffer specs pass

---

### Story 2: Fix Scrolling During Streaming & Agent Execution

**As a** user, **I want** to scroll through chat history while the agent is generating a response **so that** I can review previous messages without waiting.

- **Timebox:** 2d
- **Risk:** P0 — Inability to scroll during long responses blocks usability.

**Action Plan:**

1. **Modify** `handle_message` to run `@agent_loop.run` in a background thread (or use non-blocking I/O pattern).
2. **Create** a concurrent input reader that runs alongside the agent loop:
   - During agent execution, `read_line` becomes a "scroll-only" mode that still processes Up/Down/PgUp/PgDown.
   - Escape sequences for scroll keys are handled; all other input is queued or ignored until the agent completes.
3. **Modify** `build_stream_callback` to be thread-safe — use `Mutex` around `@messages` and `@streaming_buf` mutations, since the callback writes from the agent thread while the scroll-reader reads from the main thread.
4. **Add** a `@scroll_lock` flag — auto-scroll to bottom when new content arrives UNLESS user has manually scrolled up (offset > 0). When user scrolls back to bottom (offset == 0), re-enable auto-scroll.
5. **Modify** `render_chat_panel` — add a scroll indicator at the top/bottom of the chat panel when not at the newest messages (e.g., `▲ more above` / `▼ more below`).
6. **Test** scroll behavior: concurrent rendering + scrolling; thread safety of message buffer.

**Acceptance Criteria:**

- GIVEN the agent is streaming a response, WHEN the user presses Page Up, THEN the chat panel scrolls up and shows older messages while streaming continues in the background.
- GIVEN the user has scrolled up during streaming, WHEN new chunks arrive, THEN the view stays at the user's scroll position (no jump to bottom).
- GIVEN the user is scrolled up, WHEN they press Page Down to reach the bottom, THEN auto-scroll resumes.

**Technical Context:**

- Current blocking: `@agent_loop.run(message, @session)` blocks in `handle_message` at line 652
- Thread safety: `@messages` array is mutated by the stream callback and read by `render_chat_panel`
- Files: `lib/homunculus/interfaces/tui.rb` (handle_message, build_stream_callback, render_chat_panel, read_line)
- Dependency: Story 1 (InputBuffer) should land first so escape sequence routing is clean

**Agent Hints:**

- Class: Reasoner (reasoning) — concurrency correctness requires careful thought
- Context files: `lib/homunculus/interfaces/tui.rb:639-660` (handle_message), `lib/homunculus/agent/loop.rb:51-88` (agent loop run)
- Gate: No deadlocks; scroll works during streaming; all existing specs pass

---

### Story 3: Activity Spinner with Step Messages

**As a** user, **I want** to see a visual indicator that the agent is working, with descriptive step messages, **so that** I know the system hasn't frozen.

- **Timebox:** 1.5d
- **Risk:** P1 — Absence of feedback makes the system feel broken during long operations.

**Action Plan:**

1. **Create** `ActivityIndicator` internal module/class:
   - Braille spinner animation: `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` (cycle at ~100ms)
   - `start(message)` — begins spinner thread; renders spinner + message in the status bar or a dedicated activity row.
   - `update(message)` — changes the step message without restarting.
   - `stop` — halts spinner thread, clears the indicator.
2. **Modify** `handle_message`:
   - Before `@agent_loop.run`: `spinner.start("Thinking...")`
   - Stream callback: `spinner.update("Receiving response...")` on first chunk, then stop spinner (streaming text is its own indicator).
3. **Add** step-aware callbacks to the agent loop integration:
   - Tool execution start: `spinner.update("Running tool: #{tool_name}...")`
   - Tool execution end: `spinner.update("Processing results...")`
   - This requires either extending the stream callback protocol or adding a `status_callback` lambda.
4. **Render** the spinner in the status bar region (replace `session_status_label` content while active) or in a thin row between chat and status.
5. **Ensure** the spinner thread is cleaned up on Ctrl+C / shutdown.
6. **Test** ActivityIndicator: start/stop lifecycle, message update, thread cleanup.

**Acceptance Criteria:**

- GIVEN the user sends a message, WHEN the agent is processing, THEN a spinning animation with "Thinking..." appears in the status bar.
- GIVEN the agent calls a tool, WHEN tool execution begins, THEN the spinner message updates to show the tool name.
- GIVEN the agent starts streaming, WHEN the first chunk arrives, THEN the spinner stops and streaming text appears.

**Technical Context:**

- Spinner runs in its own thread; must coordinate with render_status_bar
- The `stream_callback` lambda is the natural hook for "first chunk" detection
- For tool step messages, the `AgentLoop` currently logs but doesn't expose callbacks — may need a lightweight event hook
- Files: `lib/homunculus/interfaces/tui.rb` (handle_message, build_stream_callback, render_status_bar)
- Dependency: Story 2 (concurrent scrolling) — the threading model must be compatible

**Agent Hints:**

- Class: Builder (speed)
- Context files: `lib/homunculus/interfaces/tui.rb:470-524` (status bar), `lib/homunculus/interfaces/tui.rb:639-660` (handle_message)
- Gate: Spinner visible during agent execution; no orphaned threads on exit

---

### Story 4: Real-Time Token Consumption Display

**As a** user, **I want** to see token counts update in real-time as the agent streams, **so that** I can monitor cost and context usage.

- **Timebox:** 1d
- **Risk:** P2 — Nice-to-have visibility; does not block core usage.

**Action Plan:**

1. **Modify** `build_stream_callback` to estimate output tokens during streaming:
   - Rough heuristic: count words in accumulated `@streaming_buf[:text]`, multiply by ~1.3 for token estimate.
   - Or, if the Ollama streaming response includes token counts in chunk metadata, parse those.
2. **Modify** `refresh_status_bar` (already called per chunk in the stream callback) to show:
   - `tokens: {input}↓ {output}↑ (+{delta}⚡)` where `delta` is the streaming estimate.
3. **After** the streaming completes, `session.track_usage` provides the real numbers — update the status bar to show final accurate counts.
4. **Investigate** Ollama's streaming response format:
   - Ollama streams JSON lines with `done: false` chunks; the final chunk (`done: true`) includes `total_duration`, `prompt_eval_count`, `eval_count`.
   - The `OllamaProvider.generate_stream` may already expose these in the final response hash.
5. **Modify** `token_usage_label` to show per-message deltas alongside session totals: `tokens: 1,240↓ 892↑ (session: 4,500↓ 3,200↑)`.
6. **Test** token display updates during streaming mock.

**Acceptance Criteria:**

- GIVEN the agent is streaming a response, WHEN tokens are being generated, THEN the status bar shows an updating token count.
- GIVEN a response completes, WHEN final token counts are available, THEN the status bar shows accurate session totals.

**Technical Context:**

- `OllamaProvider.generate_stream` yields chunks; final chunk has usage data
- `session.track_usage` is called after `@agent_loop.run` returns — the session's totals are updated at that point
- The status bar is already refreshed per streaming chunk via `refresh_status_bar` in the callback
- Files: `lib/homunculus/interfaces/tui.rb:168-178` (stream callback), `lib/homunculus/interfaces/tui.rb:484-524` (status bar), `lib/homunculus/agent/models/ollama_provider.rb`

**Agent Hints:**

- Class: Builder (speed)
- Context files: `lib/homunculus/interfaces/tui.rb:484-524`, `lib/homunculus/agent/models/ollama_provider.rb`
- Gate: Token counts visible and updating during streaming

---

### Story 5: Chat Timestamps

**As a** user, **I want** to see timestamps on each chat message **so that** I can trace conversation timing and response latency.

- **Timebox:** 0.5d
- **Risk:** P2 — Cosmetic enhancement for traceability.

**Action Plan:**

1. **Modify** `push_user_message`, `push_assistant_message`, `push_info_message`, `push_error_message` to include `timestamp: Time.now` in the message hash.
2. **Modify** `render_message` to prepend a dim timestamp to the first line of each message:
   - Format: `[HH:MM]` (hours:minutes) — compact to preserve horizontal space.
   - Style: `paint("[14:32]", :dim)` before the role label.
   - For streaming messages, the timestamp is set when the first chunk arrives.
3. **Preserve** the existing word-wrap logic — account for the timestamp prefix width in the available `width` calculation.
4. **Test** render_message includes timestamp; timestamp format is correct.

**Acceptance Criteria:**

- GIVEN any message in the chat panel, WHEN rendered, THEN it shows a `[HH:MM]` timestamp before the role label.
- GIVEN a streaming message, WHEN the first chunk arrives, THEN the timestamp reflects the start of streaming, not the end.

**Technical Context:**

- Message hash currently: `{ role:, text: }` — add `timestamp:` key
- `build_stream_callback` creates the message entry on first chunk — set timestamp there
- Files: `lib/homunculus/interfaces/tui.rb:418-441` (render_message), `lib/homunculus/interfaces/tui.rb:711-727` (message queue)

**Agent Hints:**

- Class: Builder (speed)
- Context files: `lib/homunculus/interfaces/tui.rb:418-441`, `spec/interfaces/tui_spec.rb`
- Gate: Timestamps visible on all message types; existing render specs adapted

---

### Story 6: Fix Duplicate UI Elements

**As a** user, **I want** help text and system messages to appear once and not duplicate on every command **so that** the chat stays clean.

- **Timebox:** 0.5d
- **Risk:** P1 — Visual clutter degrades the experience every session.

**Action Plan:**

1. **Diagnose** the duplication: `show_help` pushes a new `:info` message to `@messages` every call. The help text accumulates in the scrollback. Same for the initial "Type 'help' for commands" message in `input_loop`.
2. **Fix** help display — two options:
   - **Option A (overlay):** Render help as a temporary overlay on the chat panel that disappears on next input. Does not push to `@messages`.
   - **Option B (dedup):** Before pushing, check if the last message with role `:info` has the same text prefix; skip if duplicate.
   - **Recommended: Option A** — help is transient reference material, not part of the conversation.
3. **Modify** `show_help` to render directly to the chat panel region (temporary overlay), not push to `@messages`.
4. **Modify** `show_status` similarly — render as overlay or push only if content changed.
5. **Modify** `input_loop` initial message — push the welcome message once; the `@messages` array starts empty so this is fine as-is, but verify no re-entry path.
6. **Add** a `@help_visible` flag — if help is showing as overlay, any next input clears it and re-renders the real chat panel.
7. **Test** that `show_help` twice doesn't create two entries; overlay clears on input.

**Acceptance Criteria:**

- GIVEN the user types "help" twice, WHEN looking at chat history, THEN help text does not appear twice in the scrollback.
- GIVEN help is displayed, WHEN the user types a new message, THEN the help overlay disappears and the chat panel shows normally.

**Technical Context:**

- `show_help` at line 731: pushes to `@messages` then calls `refresh_all`
- `show_status` at line 747: same pattern
- Files: `lib/homunculus/interfaces/tui.rb:731-763` (show_help, show_status)

**Agent Hints:**

- Class: Builder (speed)
- Context files: `lib/homunculus/interfaces/tui.rb:731-763`
- Gate: No duplicate help entries in `@messages`; overlay renders and clears correctly

---

### Story 7: Slash Command Support with Suggestions

**As a** user, **I want** to type `/` to see available commands with autocomplete suggestions **so that** discovery is intuitive and input is faster.

- **Timebox:** 2d
- **Risk:** P1 — Commands are currently discoverable only via "help"; slash prefix is a universal chat convention.

**Action Plan:**

1. **Define** command registry:
   ```
   /help       — Show available commands
   /status     — Session and config details
   /clear      — Clear chat history
   /confirm    — Approve pending tool call
   /deny       — Reject pending tool call
   /model      — Show current model tier and routing info
   /quit       — Exit (aliases: /exit, /q)
   ```
2. **Create** `CommandRegistry` internal class:
   - `COMMANDS` hash: `{ "/help" => { description:, handler: } }`
   - `match(input)` — returns command if input starts with `/` and matches
   - `suggestions(partial)` — returns matching commands for autocomplete
3. **Modify** `process_input` to check for `/` prefix first:
   - If exact match → dispatch to handler
   - If partial match and no exact → show suggestion list as a temporary overlay
   - If no match → show "Unknown command. Type /help for available commands."
4. **Modify** `read_line` to detect `/` as first character and enter "command mode":
   - After each character, call `suggestions(buf)` and render a dropdown/overlay above the input line showing matching commands.
   - Tab key selects the top suggestion (auto-completes).
   - Escape dismisses the suggestions.
5. **Preserve** backward compatibility: bare `help`, `status`, etc. still work (keep the existing `process_input` cases, but mark them as legacy in code).
6. **Add** `/model` command that shows richer tier info than `status`:
   - Current resolved tier, model name, provider, description from `models.toml`
   - Whether escalation is enabled, budget status
7. **Test** CommandRegistry: matching, suggestions, edge cases (empty `/`, unknown command).

**Acceptance Criteria:**

- GIVEN the user types `/`, WHEN they continue typing, THEN matching commands appear as suggestions above the input line.
- GIVEN the user types `/he` and presses Tab, THEN the input auto-completes to `/help`.
- GIVEN the user types `/help` and presses Enter, THEN the help text is displayed.
- GIVEN the user types `/model`, THEN the current tier name, model, and provider are displayed.

**Technical Context:**

- `process_input` at line 614: current dispatch uses `case input.downcase`
- Suggestion overlay: render 1-N lines above the input line (temporarily overwrite bottom of chat panel)
- Files: `lib/homunculus/interfaces/tui.rb:614-635` (process_input), `lib/homunculus/interfaces/tui.rb:556-612` (read_line)
- Dependency: Story 1 (InputBuffer) — the buffer needs to expose the current text for suggestion matching

**Agent Hints:**

- Class: Builder (speed)
- Context files: `lib/homunculus/interfaces/tui.rb:614-635`, `config/models.toml`
- Gate: Slash commands work; suggestions appear; Tab completion works; backward compat preserved

---

### Story 8: Enhanced Model Tier Display

**As a** user, **I want** to easily understand which model tier is handling my request **so that** I can gauge response quality and cost.

- **Timebox:** 1d
- **Risk:** P2 — Clarity improvement; current "model: router" is opaque.

**Action Plan:**

1. **Modify** `model_tier_label` in the status bar to show the resolved tier name and model:
   - Instead of `model: router` → `model: workhorse (qwen3:14b)`
   - During escalation: `model: cloud_fast (claude-haiku) ⚡ escalated from workhorse`
2. **Track** the current tier in TUI state:
   - Add `@current_tier` instance variable, updated when the router resolves a tier.
   - The `Models::Response` already includes `tier` and `provider` — expose this via the stream callback or agent result.
3. **Modify** `build_stream_callback` to capture tier info from the first streaming event (or from the router before the call).
4. **Modify** `display_result` to update `@current_tier` from the `AgentResult`'s session or response metadata.
5. **Color-code** tiers in the status bar:
   - Local tiers (whisper, workhorse, coder, thinker): green
   - Cloud tiers (cloud_fast, cloud_standard, cloud_deep): yellow
   - Escalated: red background
6. **Add** tier description from `models.toml` in the `/model` command (Story 7).
7. **Test** tier label rendering for each tier type; color coding.

**Acceptance Criteria:**

- GIVEN a response using the workhorse tier, WHEN looking at the status bar, THEN it shows `workhorse (qwen3:14b)` in green.
- GIVEN an escalation to cloud, WHEN looking at the status bar, THEN it shows the cloud tier with an escalation indicator.

**Technical Context:**

- `Models::Response` includes `tier`, `provider`, `model`, `escalated_from`
- The `complete_via_models_router` in `loop.rb` returns `[response, provider]` — the tier is in the response
- `models_response_to_loop_response` converts but doesn't preserve tier info — may need to propagate it
- Files: `lib/homunculus/interfaces/tui.rb:496-503` (model_tier_label), `lib/homunculus/agent/loop.rb:167-181`, `config/models.toml`

**Agent Hints:**

- Class: Builder (speed)
- Context files: `lib/homunculus/interfaces/tui.rb:484-524`, `lib/homunculus/agent/models/router.rb`, `config/models.toml`
- Gate: Tier name + model visible in status bar; escalation marked; colors applied

---

## Execution Sequence

```
Story 1 (Input Buffer)          ─────────────┐
                                             │
Story 5 (Timestamps)            ─────┐       ├─→ Story 7 (Slash Commands)
                                     │       │       depends on Story 1, 6
Story 6 (Fix Duplicates)        ─────┤       │
                                     │       │
Story 2 (Scrolling Fix)        ──────┼───────┤
  depends on Story 1                 │       │
                                     │       │
Story 3 (Spinner)              ──────┤       │
  depends on Story 2                 │       │
                                     │       │
Story 4 (Token Display)        ──────┘       │
  depends on Story 3                         │
                                             │
Story 8 (Tier Display)         ──────────────┘
  depends on Story 4
```

**Recommended order:** 1 → 5 → 6 → 2 → 3 → 4 → 7 → 8

**Parallelizable pairs:** Stories 5+6 can run in parallel. Story 1 is a hard prerequisite for 2 and 7.

---

## Files Changed

| Action | File | Stories |
|--------|------|---------|
| EDIT | `lib/homunculus/interfaces/tui.rb` | 1–8 |
| NEW (optional) | `lib/homunculus/interfaces/tui/input_buffer.rb` | 1 |
| NEW (optional) | `lib/homunculus/interfaces/tui/activity_indicator.rb` | 3 |
| NEW (optional) | `lib/homunculus/interfaces/tui/command_registry.rb` | 7 |
| EDIT | `lib/homunculus/agent/loop.rb` | 3 (status callbacks), 8 (tier propagation) |
| EDIT | `spec/interfaces/tui_spec.rb` | 1–8 |
| NEW | `spec/interfaces/tui/input_buffer_spec.rb` | 1 |
| NEW | `spec/interfaces/tui/command_registry_spec.rb` | 7 |

---

## Confidence Report

| Factor | Score | Notes |
|--------|-------|-------|
| Pattern match | 90% | Existing region-based rendering is a strong skeleton; well-tested |
| Requirement clarity | 85% | All 8 augmentations clearly stated; token "real-time" has nuance (heuristic vs actual) |
| Decomposition stability | 85% | Stories are independent enough; dependency chain is linear and clear |
| Constraint compliance | 90% | No security changes; no new gems; Ruby 4.0 compatible; tests maintained |
| **Overall** | **87%** | **AUTO_PROCEED** |

---

## Technical Notes

- **Threading model:** Story 2 introduces concurrency. Ruby's GVL means true parallelism is limited, but `Thread.new` with `Mutex` synchronization is sufficient for I/O-bound work (reading stdin while waiting for HTTP streaming). The agent loop is I/O-bound (HTTP to Ollama), so this will work well.
- **TUI file size:** The TUI is already 577 lines. With 8 stories, it will grow significantly. Extracting `InputBuffer`, `ActivityIndicator`, and `CommandRegistry` into `lib/homunculus/interfaces/tui/` submodules is recommended to stay under the 700-line class limit (RuboCop).
- **Escape sequence handling:** The current `consume_escape_sequence` reads up to 8 bytes non-blocking. This is fragile — some terminals send longer sequences. Story 1 should improve this with a proper escape parser that reads until a terminal character ([A-Z~]) is found.
- **Backward compatibility:** Bare commands (help, status, etc.) must continue working alongside `/help`, `/status`. Mark them as legacy but don't remove.
