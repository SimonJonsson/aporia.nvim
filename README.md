# aporia.nvim

> *aporia* (Ancient Greek) — a state of puzzlement; the impasse Socrates
> deliberately drove his interlocutors into, where "I thought I knew" turns
> into "why did I think I knew?"

aporia is a way of writing code with an LLM while staying fully locked in:
you write every line, and the model makes you faster and sharper around it.
It has two modes:

- **Assist** augments you as far as possible short of writing your code. It
  explains, locates the right API, diagnoses errors, reviews and plans, and
  answers directly.
- **Teach** is for the impasses worth having. It runs named exercises against
  known learning traps and asks questions instead of answering them.

## Design guarantees

1. **You write the code.** There is no code path that edits your buffers, and
   neither mode hands you a solution you could paste in.
2. **No unprompted output.** No completion, no ghost text, no notifications
   without a keypress.
3. **The mode is always explicit.** Assist and teach have their own keys,
   prompts and conversations; you always know which one you are talking to.
4. **Every claim carries a verification path**, or is flagged "unverified".
5. **Docs are cheaper than AI.** `K`, `gd`, `:help` stay one keystroke.

## Keys

Teach mode lives on `<leader>t`, assist mode on `<leader>a`. Each mode keeps
its own conversation and system prompt: assist answers directly (explain,
locate, diagnose, review, plan), teach asks questions. Any trap switches to
teach. The input box shows the active mode and the border colour follows it
(`AporiaBorderAssist` / `AporiaBorderTeach`).

| Key | Trap | Exercise |
|---|---|---|
| `<leader>tq` | Forming | Question check |
| `<leader>th` | Dislodging | Hint ladder (stops at level 3) |
| `<leader>tr` | Assumption | Reframe |
| `<leader>ts` | Location | Step audit |
| `<leader>tc` | Achievement | Root-cause challenge |
| `<leader>tl` | Progression | Learning log |
| `<leader>tt` | — | Toggle chat in teach mode |
| `<leader>at` | — | Toggle chat in assist mode |
| `<leader>aa` | — | Stage selection as context |
| `<leader>ab` | — | Stage buffer as context |

Inside the chat: the history is read-only; the input window at the bottom is
where you type. `<CR>` sends, `<C-j>` breaks the line, `q` hides the sidebar.

Typing `/` at the start of the input opens a command menu that narrows as you
type: fuzzy on command names, word prefixes on descriptions (`/switch` finds
`/assist` and `/teach`). `<C-n>`/`<C-p>` move through it, `<C-y>` accepts, `<C-e>`
dismisses; `<CR>` always sends exactly what you typed. Start a message with
`//` to send a literal leading slash.

| Command | |
|---|---|
| `/new` | fresh conversation in the current mode (the old one stays on disk) |
| `/assist`, `/teach` | switch mode |
| `/reset` | wipe both conversations and staged context |
| `/delete-all-sessions` | delete every saved session in this project (asks first) |

## Setup

```lua
{
  "SimonJonsson/aporia.nvim",
  cmd = "Aporia",
  -- modes matter: visual-mode staging must work from a cold start, and the
  -- descs are what which-key shows before the plugin has loaded
  keys = {
    { "<leader>tq", mode = { "n", "v" }, desc = "Question check" },
    { "<leader>th", mode = { "n", "v" }, desc = "Hint ladder" },
    { "<leader>tr", mode = { "n", "v" }, desc = "Reframe" },
    { "<leader>ts", mode = { "n", "v" }, desc = "Step audit" },
    { "<leader>tc", mode = { "n", "v" }, desc = "Root-cause challenge" },
    { "<leader>tl", mode = { "n", "v" }, desc = "Learning log" },
    { "<leader>tt", mode = { "n", "v" }, desc = "Toggle chat (teach)" },
    { "<leader>at", mode = { "n", "v" }, desc = "Toggle chat (assist)" },
    { "<leader>aa", mode = { "n", "v" }, desc = "Stage selection" },
    { "<leader>ab", mode = { "n", "v" }, desc = "Stage buffer" },
  },
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

On load, aporia labels `<leader>a` "aporia assist" and `<leader>t` "aporia
teach" in which-key (v3+); set `which_key_groups = false` to skip that, or
pass your own `{ [prefix] = label }` table if you remapped. To get the labels
before the plugin loads (LazyVim), declare them on which-key:

```lua
{ "folke/which-key.nvim", opts = { spec = {
  { "<leader>a", group = "aporia assist", mode = { "n", "v" } },
  { "<leader>t", group = "aporia teach", mode = { "n", "v" } },
} } }
```

`:Aporia` toggles the chat; `:Aporia assist|teach` opens it in that mode; `:Aporia question|hint|reframe|steps|rootcause|log`
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

Requests are non-streaming by design: replies are short, and one
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
bottom of the chat, and sent with provenance so aporia can cite locations:

- `<leader>aa` stages the visual selection plus surrounding context lines,
  marked `From path:start-end`
- `<leader>ab` stages the whole buffer (truncated at
  `context.max_lines`)
- Fetched docs land in the same tray

## Documentation fetching

aporia never browses on its own. Replies contain reference blocks
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
dial. aporia currently sees only what you stage; letting assist mode navigate
the codebase itself (LSP, grep, file reads) is planned.

## Sessions

Conversations are saved per project in `.aporia/` at the project root: the
nearest directory above the working directory that holds `.aporia/` or
`.git`. The directory ignores itself (`.aporia/.gitignore` contains `*`), so
your repository's ignore file is left alone. Outside a project nothing is
written.

```
.aporia/
  .gitignore
  sessions/
    assist/20261029-104211.json
    teach/20261029-093000.json
```

Opening the chat restores the newest session of each mode. `/new`, `x` and
`:Aporia reset` start a fresh one; earlier sessions stay on disk until
`/delete-all-sessions` (or `:Aporia delete-all-sessions`) removes
`.aporia/sessions/` after a confirmation.

```lua
opts = {
  persist = {
    enabled = true,
    dir = ".aporia",
    markers = { ".aporia", ".git" },
  },
}
```

## Learning log

`<leader>tl` asks aporia to summarise the session into two lines
(`learned:` / `still needed AI for:`), lets you edit them, and appends

```
YYYY-MM-DD | learned: … | still needed AI for: …
```

to `log_file` (default `~/notes/learning.md`) on your confirmation. If the
second column stops shrinking over weeks of review, that is the alarm.

## Status

Working: chat sidebar with read-only history and dedicated input window,
provider table (OpenAI-compatible), assist and teach modes with separate
conversations, staging queue with provenance, six trap prompts, learning log,
fetch gate, three-tier key resolution.
Not yet: assist-mode codebase navigation (read-only tools), a general fold
tree for the chat, treesitter scope expansion for selections, HTML-to-text
for fetched docs, vimdoc tag generation.

## Development

```sh
make test        # plenary.busted
make lint        # selene + stylua --check (tools not bundled)
```

Requires: Neovim 0.10+, curl. No other runtime dependencies.
