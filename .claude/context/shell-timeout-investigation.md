# Shell Execution Timeout Error — Investigation Report

## Summary

**Error observed:** `Shell execution error: wrong exec option symbol: timeout`

**Reproduced:** Yes — via `bin/dev run ruby -e "Open3.capture3('date', timeout: 30)"` → `ArgumentError: wrong exec option symbol: timeout`

## Root Cause

`Open3.capture3` forwards its options hash to `Process.spawn`. The `Process.spawn` exec options in Ruby do **not** include `:timeout` as a valid symbol. Valid options include: `:chdir`, `:unsetenv_others`, `:umask`, `:pgroup`, `:new_pgroup`, `:rlimit_*`, `:close_others`, file descriptor redirects, etc. Passing `timeout:` causes Ruby to raise `ArgumentError: wrong exec option symbol: timeout`.

**Affected files:**
1. `lib/homunculus/tools/shell.rb` — lines 70 and 86
2. `lib/homunculus/security/sandbox.rb` — lines 48 and 61

Both pass `timeout:` to `Open3.capture3(*cmd, timeout:)`, which is invalid.

## Solution Approach

Use Ruby's `Timeout` module to wrap the `Open3.capture3` call instead of passing `timeout:` as an exec option:

```ruby
# Before (broken):
stdout, stderr, status = Open3.capture3(*docker_cmd, timeout:)

# After (correct):
stdout, stderr, status = Timeout.timeout(timeout) { Open3.capture3(*docker_cmd) }
```

The `rescue Timeout::Error` blocks already exist and will continue to handle timeouts correctly.

## Reference

- Ruby Process.spawn: https://docs.ruby-lang.org/en/3.3/Process.html#method-c-spawn — no `:timeout` in exec options
- Ruby Open3.capture3: passes options to Process.spawn; only `stdin_data` and `binmode` have local effect
- Existing pattern in codebase: `lib/homunculus/agent/loop.rb` line 481 uses `Timeout.timeout(...) { ... }`

## Test Expectations

- `spec/tools/shell_spec.rb` line 264 expects `Open3.capture3(..., timeout: 30)` — stub must be updated to match new call signature (no `timeout:` kwarg; Timeout.timeout wraps the call)
- All other specs that stub `Open3.capture3` may need similar updates if they assert on keyword args
