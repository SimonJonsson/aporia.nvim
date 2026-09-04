# aporia.nvim

An AI tutor for Neovim that never writes code.

The LLM is available only as a teacher: it cannot edit buffers, cannot act
unprompted, and every interaction is a named exercise against a known
learning trap. The name is the point: *aporia* — the productive state of
puzzlement the tutor is supposed to leave you in.

## Design guarantees

1. **No buffer writes.** There is no code path that edits your code.
2. **No unprompted output.** No completion, no ghost text, no notifications
   without a keypress.
3. **One keymap per trap.** No generic "ask AI anything" binding.
4. **Questions before answers.** The tutor's job is to make you think.
5. **Every claim carries a verification path**, or is flagged "unverified".
6. **Docs are cheaper than AI.** `K`, `gd`, `:help` stay one keystroke.

## Traps

| Key | Trap | Exercise |
|---|---|---|
| `<leader>aq` | Forming | Question check |
| `<leader>ah` | Dislodging | Hint ladder (stops at level 3) |
| `<leader>ar` | Assumption | Reframe |
| `<leader>as` | Location | Step audit |
| `<leader>ac` | Achievement | Root-cause challenge |
| `<leader>al` | Progression | Learning log |
| `<leader>at` | — | Toggle chat |
| `<leader>aa` | — | Stage selection as context |
| `<leader>ab` | — | Stage buffer as context |

## Status

Scaffold. Working: chat buffer, provider table (OpenAI-compatible), staging
queue with provenance, six trap prompts, learning log, fetch gate.
Not yet: treesitter scope expansion for selections, HTML-to-text for fetched
docs, vimdoc tag generation.

## Development

```sh
make test        # plenary.busted
make lint        # selene + stylua --check (tools not bundled)
```

Requires: Neovim 0.10+, curl. No other runtime dependencies.
