# TUI Complete Rework Plan
**Date:** 2026-03-13
**Type:** CHANGE — Rework existing subsystem with deep architectural issues
**Complexity:** 10/12

## Problem Statement

The TUI has 6 persistent issue categories surviving multiple iterations:
1. UI constant blinks (moving cursor, arrow keys)
2. Cursor glitches across screen
3. Outputs cut off until next message sent
4. Inputs get overridden when sent
5. Commands/tool confirmations glitch the page
6. Layout too shrunk, markdown renders poorly

## Root Cause Analysis

| Issue | Root Cause |
|-------|-----------|
| Blinking | `clear_line` + `$stdout.write` per line = visible blank frame |
| Cursor glitches | `read_nonblock(8)` reads wrong byte counts; escape sequences bleed |
| Output cut off | `preserve_scroll_position` re-renders twice; race with streaming |
| Input override | ActivityIndicator thread writes `move_to` + content, interleaving with input |
| Tool confirm glitches | Suggestion row clearing overlaps chat panel; concurrent render |
| Layout/markdown | `inner_width = term_width - 2` steals space; code blocks double-indented |

## Selected Architecture: Event Loop + Virtual Screen Buffer (Hypothesis D)

**Rationale:** Root cause of issues 1-5 is concurrent, uncoordinated writes to stdout from multiple threads. An event loop naturally solves this: ActivityIndicator pushes tick events, stream chunks push data events, keypresses push input events. Single-threaded rendering eliminates all interleaving.

### Alternatives Considered

| Alternative | Why Rejected |
|------------|--------------|
| A: Surgical fixes | Addresses symptoms, not causes. Threading model fundamentally broken |
| B: Screen buffer only | Solves blink but not concurrent-writes. Necessary but not sufficient — absorbed into D |
| C: TTY gems | External dependency doesn't solve core problem. Adds risk without eliminating architecture issue |

## Stories

### Feature 1: Rendering Pipeline Rework

#### Story 1.1: Screen Buffer (Virtual Frame Buffer) — P0, 3d
- NEW `lib/homunculus/interfaces/tui/screen_buffer.rb`
- NEW `lib/homunculus/interfaces/tui/ansi_parser.rb`
- 2D cell grid with `{char, fg, bg, attrs}` structs
- `flush(io)` diffs current vs previous frame, emits minimal escape sequences in one atomic write
- `force_flush(io)` for resize/initial render

#### Story 1.2: Event Loop Architecture — P0, 3d
- NEW `lib/homunculus/interfaces/tui/event_loop.rb`
- `Thread::Queue` for event passing
- Event types: `:keypress`, `:stream_chunk`, `:spinner_tick`, `:resize`, `:agent_result`, `:shutdown`, `:refresh`
- Main loop: drain queue → handle events → render ONE frame → sleep(0.016) if idle (60fps cap)
- ActivityIndicator pushes `:spinner_tick` events instead of calling redraw
- Stream callback pushes `:stream_chunk` events
- Depends on: 1.1

#### Story 1.3: Keyboard Reader with Escape Sequence Parsing — P0, 2d
- NEW `lib/homunculus/interfaces/tui/keyboard_reader.rb`
- Proper escape sequence state machine (not `read_nonblock(8)` heuristic)
- 50ms timeout for bare Escape disambiguation
- Semantic key events: `:arrow_left`, `:page_up`, `:enter`, etc.
- Handles multi-byte UTF-8

### Feature 2: Layout and Content Rendering

#### Story 2.1: Viewport and Layout Manager — P1, 2d
- NEW `lib/homunculus/interfaces/tui/layout.rb`
- Computes region boundaries: header, chat, status, separator, input
- Full terminal width for content (remove `inner_width = term_width - 2` bottleneck)
- `chat_width = term_width - 2` (aesthetic margins only)
- Recalculates on resize

#### Story 2.2: Markdown Rendering Improvements — P1, 2d
- MODIFY `lib/homunculus/interfaces/tui/message_renderer.rb`
- Code blocks: left border (`│`) + language label, no double-indentation
- Nested list support with proper bullet alignment
- Heading visual distinction (color/underline)
- Style annotations instead of embedded ANSI (leveraging ScreenBuffer)

### Feature 3: Input and Interaction

#### Story 3.1: Input Isolation from Rendering — P0, 1d
- Explicit mode system: `:input`, `:thinking`, `:confirm`
- Tool confirmation: dedicated mode with restricted input
- Mode indicator in status bar
- Depends on: 1.2

#### Story 3.2: Scroll Viewport During Streaming — P1, 1d
- Auto-scroll when at bottom; preserve position when scrolled up
- Scroll indicators: "... more above/below ..."
- Simplified logic (no mutex needed with event loop)
- Depends on: 1.2, 1.1

### Feature 4: Integration and Cleanup

#### Story 4.1: Integrate All Components — P0, 3d
- Rewrite `TUI#start` to initialize all new components
- Rewrite `render_frame` to compose regions via ScreenBuffer
- Remove ALL direct `$stdout.write` outside ScreenBuffer#flush
- Remove `@render_mutex`, simplify `@messages_mutex`
- Target: TUI class under 700 lines (RuboCop limit)

#### Story 4.2: Update Test Suite — P1, 2d
- Specs for ScreenBuffer, EventLoop, KeyboardReader, Layout
- Update existing TUI specs for new architecture
- Coverage: 75% overall / 30% per file

## Execution Sequence

```
Story 1.1 (Screen Buffer)     ───┐
Story 1.3 (Keyboard Reader)   ───┤
Story 2.1 (Layout Manager)    ───┼──→ Story 1.2 (Event Loop) ──→ Story 3.1 (Input)
Story 2.2 (Markdown Fixes)    ───┤                           ──→ Story 3.2 (Scroll)
                                  │                           ──→ Story 4.1 (Integration)
                                  │                                      └──→ Story 4.2 (Tests)
```

**Parallelizable:** 1.1, 1.3, 2.1, 2.2 have no dependencies between them.

## Files Changed

| Action | File |
|--------|------|
| NEW | `lib/homunculus/interfaces/tui/screen_buffer.rb` |
| NEW | `lib/homunculus/interfaces/tui/ansi_parser.rb` |
| NEW | `lib/homunculus/interfaces/tui/event_loop.rb` |
| NEW | `lib/homunculus/interfaces/tui/keyboard_reader.rb` |
| NEW | `lib/homunculus/interfaces/tui/layout.rb` |
| MAJOR MODIFY | `lib/homunculus/interfaces/tui.rb` |
| MODIFY | `lib/homunculus/interfaces/tui/message_renderer.rb` |
| MODIFY | `lib/homunculus/interfaces/tui/activity_indicator.rb` |
| MODIFY | `lib/homunculus/interfaces/tui/theme.rb` |
| NEW | `spec/interfaces/tui/screen_buffer_spec.rb` |
| NEW | `spec/interfaces/tui/event_loop_spec.rb` |
| NEW | `spec/interfaces/tui/keyboard_reader_spec.rb` |
| NEW | `spec/interfaces/tui/layout_spec.rb` |
| MODIFY | `spec/interfaces/tui/message_renderer_spec.rb` |
| MODIFY | `spec/interfaces/tui_spec.rb` |

## Confidence: 86% — AUTO_PROCEED
