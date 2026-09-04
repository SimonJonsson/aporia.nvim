# aporia.nvim

> *aporia* (Ancient Greek) — a state of puzzlement; the impasse Socrates
> deliberately drove his interlocutors into, where "I thought I knew" turns
> into "why did I think I knew?" That state is the product. The tutor's job is
> to bring you there and leave you there, equipped.

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

Inside the chat: the history is read-only; the input window at the bottom is
where you type. `<CR>` sends, `<C-j>` breaks the line, `q` hides the sidebar.

## Setup

```lua
{
  "SimonJonsson/aporia.nvim",
  cmd = "Aporia",
  keys = { "<leader>aq", "<leader>ah", "<leader>ar", "<leader>as",
           "<leader>ac", "<leader>al", "<leader>at", "<leader>aa", "<leader>ab" },
  opts = {
    provider = "baseten",
    providers = {
      baseten = {
        base_url = "https://inference.baseten.co/v1",
        model = "your-model-id",
      },
    },
  },
}
```

`:Aporia` toggles the chat; `:Aporia question|hint|reframe|steps|rootcause|log`
run the trap exercises; `:Aporia reset` wipes the session;
`:checkhealth aporia` verifies provider, key, curl and log file.

## Providers

Any OpenAI-compatible endpoint works: Baseten, OpenAI, vLLM, llama.cpp,
NInfer, Ollama's OpenAI shim. Adding one is a table row:

```lua
opts = {
  providers = {
    openai = { base_url = "https://api.openai.com/v1", model = "…", api_key_env = "OPENAI_API_KEY" },
    local_model = { base_url = "http://localhost:8000/v1", model = "…" },
  },
}
```

Requests are non-streaming by design: tutor replies are short, and one
render-once draw keeps the implementation simple and the behaviour inspectable.

## API keys

Resolved per provider, in order:

1. `api_key` — literal string (only sensible for local servers)
2. `api_key_env` — environment variable, e.g. `BASETEN_API_KEY`
3. `api_key_cmd` — shell command whose stdout is the key

The default Baseten config falls back to the GNOME keyring, which also works
when nvim is launched from a desktop entry where shell environment variables
are absent:

```sh
secret-tool store --label=aporia service baseten api_key
# paste the key, Ctrl-D to finish
```

Keys are never written to config files or logs. `:checkhealth aporia` reports
which tier served the key, never the key itself.

## Context staging

Staged blocks are attached to your next message, shown in the tray at the
bottom of the chat, and sent with provenance so the tutor can cite locations:

- `<leader>aa` stages the visual selection plus surrounding context lines,
  marked `From path:start-end`
- `<leader>ab` stages the whole buffer (truncated at
  `context.max_lines`)
- Fetched docs land in the same tray

## Documentation fetching

The tutor never browses on its own. Replies contain reference blocks
(`name — URL` plus a one-line description). When it needs a page's contents
it must emit a `FETCH: <url>` line, and what happens then is your friction
dial:

```lua
opts = {
  fetch = {
    mode = "confirm",           -- "links" | "confirm" | "auto"
    max_fetches_per_turn = 2,
  },
}
```

`links` shows URLs only; `confirm` asks before every fetch; `auto` fetches
within a turn, bounded by the per-turn limit. Codebase access is not on this
dial — there is no code path where the tutor reads your repository.

## Learning log

`<leader>al` asks the tutor to summarise the session into two lines
(`learned:` / `still needed AI for:`), lets you edit them, and appends

```
YYYY-MM-DD | learned: … | still needed AI for: …
```

to `log_file` (default `~/notes/learning.md`) on your confirmation. If the
second column stops shrinking over weeks of review, that is the alarm.

## Status

Working: chat sidebar with read-only history and dedicated input window,
provider table (OpenAI-compatible), staging queue with provenance, six trap
prompts, learning log, fetch gate, keyring-backed key resolution.
Not yet: treesitter scope expansion for selections, HTML-to-text for fetched
docs, vimdoc tag generation.

## Development

```sh
make test        # plenary.busted
make lint        # selene + stylua --check (tools not bundled)
```

Requires: Neovim 0.10+, curl. No other runtime dependencies.
