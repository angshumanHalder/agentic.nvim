# Session history and rendering performance

Measured on 2026-10-26, macOS 27.0.1, Neovim 0.12.5 / LuaJIT.
Baseline: `f0bef08` (upstream main when this work started). Raw samples:
[baseline](benchmarks/baseline.json), [optimized](benchmarks/optimized.json).

## Architecture and findings

`AgentInstance` owns a shared ACP process per provider. `ACPClient` negotiates
capabilities and routes notifications by session ID. Each `SessionManager` owns
its own `ChatHistory`, `MessageWriter`, tools, permissions, and widget.
`ChatWidget` keeps separate read-only output and editable input buffers.
`SessionRegistry.show_session` switches widgets without replaying their buffers.

Discovery is `SessionRestore.show_picker` → `ACPClient:list_sessions` →
`session/list`. Restoration uses the same registry replacement/startup path as
before, subscribes before `session/load`, and consumes replayed `session/update`
notifications. Existing managers with the same ACP ID are reused.

Two reproducible problems were found:

1. `SessionListResponse.nextCursor` existed in the types, but the picker ignored
   it and the client could not send `cursor`. Only the first page was reachable.
   The picker now offers **Load more sessions…**, retains previous choices,
   deduplicates by full ID, and stops repeated cursor cycles. A failed page
   preserves earlier results and offers a retry. Cancellation fetches nothing
   further. Cursors remain opaque and are never persisted.
2. `MessageWriter:_append_lines` called `BufHelpers.is_buffer_empty` on every
   append. That helper copies the entire buffer to Lua before inspecting it.
   Loading 1,000 fixture messages copied 24 million lines. The writer now checks
   emptiness only for a one-line buffer; longer buffers are appended directly.
   No complete unchanged history is repainted or copied.

There was no full-buffer replacement on the normal append/stream path.
Streaming already uses tail `set_text`; thinking highlights reuse an extmark.
Tool bodies update between stable anchors, retaining manual folds. None of those
paths needed replacement. The fixture's 100 completed tools create the same 400
extmarks before and after. Large histories remain in both `ChatHistory` and the
buffer; this change removes transient copying, not retained conversation data.

## Markdown

`syntax/AgenticChat.vim` adds selective native syntax for headings, unordered and
ordered lists, tables, fenced blocks, bold/italic emphasis, and inline code.
It reuses standard Markdown highlight names. There are no per-line decorations,
language parsers, renderer dependencies, or new keymaps. Normal `:syntax enable`
is required; `:setlocal syntax=OFF` disables presentation in the chat buffer.

An intermediate implementation using the complete runtime Markdown syntax took
about 101 ms for 100 page-down motions at 1,000 messages. The selective syntax
reduced that to 25 ms. It avoids HTML syntax and fenced-language injections.
Highlighting scans only the first 300 columns, with native synchronization set to
50/200 lines. These bounds favor responsiveness over full Markdown parsing.

## Reproducing

From the changed checkout:

```sh
AGENTIC_BENCH_OUTPUT=/tmp/optimized.json timeout 120 nvim --headless -u NONE -i NONE -l scripts/benchmark.lua
```

For the unchanged baseline, use the **same script** with the baseline as cwd:

```sh
git worktree add --detach .worktrees/baseline f0bef08
cd .worktrees/baseline
AGENTIC_BENCH_OUTPUT=/tmp/baseline.json timeout 120 nvim --headless -u NONE -i NONE -l ../../scripts/benchmark.lua
```

The script starts a child Neovim with an attached 120×40 RGB UI, so explicit
redraws exercise the screen grid and syntax engine. It requires only Neovim and
its standard Lua APIs. No ACP executable or test dependency is needed. Run each
benchmark without other heavy work; the script exits on failed self-checks.

Each workload has five samples, following a discarded 100-message warm-up.
Each text message contains a heading, list, emphasis, table and fenced Lua block;
one in ten messages is a completed tool call. Load measures writer replay plus
redraw, with API wrappers counting copied lines, line writes and extmark writes.
Scrolling issues 100 page-down motions, with a redraw after each. Streaming
starts at the bottom and appends 1,000 chunks, redrawing every 16 chunks. This
models bursts, not wall-clock token arrival delays. Actual session switching
uses the registry's hide/show path between two widgets, one with the requested
history size (text messages for this workload), for ten round trips (20 transitions), redrawing after each pair.
The extra buffer-only switching measurement is retained in the raw JSON.

Pagination uses the real ACP list method and picker, with synchronous mock
responses containing 100 sessions per page and automatic selection of the next
page entry. Provider startup, network, disk history reads, and terminal/GPU
painting are excluded. This is a renderer and client benchmark, not an end-to-end
provider latency claim. Memory is measured after collection, with fixtures and
writer state still alive; RSS includes the Neovim runtime and syntax caches.

## Results

All latency values below are medians in milliseconds. Navigation and streaming
columns report **whole workloads**, not individual operations.

| Messages | Load before | Load after | Scroll ×100 before | Scroll ×100 after | Stream ×1000 before | Stream ×1000 after | Session transitions ×20 before | Session transitions ×20 after |
| -------- | ----------: | ---------: | -----------------: | ----------------: | ------------------: | -----------------: | -----------------------------: | ----------------------------: |
| 100      |        7.24 |       2.17 |               2.30 |              7.70 |               38.27 |              46.32 |                           5.48 |                          6.82 |
| 500      |      143.01 |       9.84 |               4.91 |             22.24 |               38.65 |              46.53 |                           6.23 |                          7.36 |
| 1000     |      549.77 |      19.15 |               5.02 |             25.14 |               38.99 |              46.94 |                           6.88 |                          8.11 |

The 1,000-message replay is about 29× faster. Syntax adds measurable overhead
against the previously unhighlighted baseline: at 1,000 messages, page-down
averages 0.25 ms, streamed chunks average 0.047 ms, and session transitions
average 0.41 ms. These averages are not tail-latency guarantees. No streaming
batch queue was added: measured cost did not justify changing delivery ordering.

| Messages | Lines copied before | Lines copied after | Buffer bytes (both) | Retained Lua KiB before / after | RSS MiB before / after |
| -------- | ------------------: | -----------------: | ------------------: | ------------------------------: | ---------------------: |
| 100      |              241076 |                 31 |               18330 |                 1289.5 / 1316.8 |            8.30 / 8.23 |
| 500      |             6010376 |                151 |               67650 |                 1379.9 / 1404.8 |            9.97 / 8.94 |
| 1000     |            24033251 |                301 |              129300 |                 1481.0 / 1502.3 |            9.23 / 9.50 |

Memory results are process-specific, not an asserted memory reduction. The
remaining copied lines belong to tool rendering. Line writes and extmark counts
are unchanged. The optimized picker retrieves ten pages / 1,000 sessions in
10.10 ms of mock client work. The baseline takes 1.53 ms but reaches only the
first page / 100 sessions, so these durations describe different completed work.

## Provider behavior and limits

Claude Code (`claude-acp` / `claude-agent-acp`), Codex (`codex-acp`) and Gemini
(`gemini-acp`) still use the same shared UI and generic ACP client. Behavior is
negotiated at runtime; no provider-name branches or ID conversions were added.
Actual installed provider versions and credentials were not exercised.

- Listing requires advertised `sessionCapabilities.list` (the standard object
  shape and the existing boolean shape are accepted). Without it, the client
  reports unsupported listing and sends no request.
- Loading a fresh target requires `loadSession`. Without listing, direct restore
  by known ID still works if loading is supported. Without loading, an already
  open matching session can still be shown. There is no fabricated local disk
  history fallback.
- The picker preserves the existing current-working-directory filter. Sessions
  from another directory, account, or provider are not made discoverable by
  pagination. Provider retention, CLI interoperability and which histories are
  exposed remain provider responsibilities.
- ACP `session/load` replays conversation updates; session-list pagination does
  not paginate conversation content. The loaded buffer remains unbounded and
  restoration remains synchronous per delivered update. Message virtualization,
  older-message prepending, scroll anchoring for prepends, and asynchronous bulk
  restoration were not introduced because the measured 1,000-message workload
  no longer needed them. Much larger histories or giant tool outputs can still
  require such work. Existing scroll-preservation and permission tests remain.
- Markdown is a highlighting subset, not a CommonMark layout engine: no table
  column alignment, nested emphasis guarantees, embedded-language highlighting,
  or markup concealment. Very long lines and jumps into fences beginning beyond
  the syntax synchronization window can lose highlighting accuracy. Text is
  preserved. Syntax scanning bounds can be adjusted through native options.

The capability and pagination contracts follow the
[ACP session-list specification](https://agentclientprotocol.com/protocol/v1/session-list)
and [session-load specification](https://agentclientprotocol.com/protocol/v1/session-setup).

## Verification

Regression coverage includes opaque cursors, on-demand fetching, empty pages,
duplicate IDs, repeated cursors, failed-page retries, malformed responses,
unsupported capabilities, full-ID restoration, unchanged streaming prefixes,
read-only output, editable input, and Markdown token highlighting. Existing
restoration, permission, diff, model/provider switching, and session lifecycle
tests are also run. Reverting each production fix makes its regression fail.

`make validate SELENE=/private/tmp/agentic-tools/selene` runs formatting, LuaLS,
Selene, the full test suite, and rule checks. The explicit Selene path is only a
local tool override; no dependency or tooling configuration was changed.
All five checks passed, including 1,414 tests across 63 groups. Self-review
found no remaining issues or rule gaps.
