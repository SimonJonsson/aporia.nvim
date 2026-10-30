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
| `/resume` | pick a saved conversation of the current mode and continue it |
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

Replies stream into the chat as they are generated. While a thinking model
reasons, the reply reads "Thinking…"; the reasoning itself is not shown or
saved. A reply cut off by an error stays visible, marked as an error, and is
left out of the history sent to the model.

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
dial; see below.

## Reading the project (assist mode)

With the backend built (`make backend`), assist mode can look around the
project before it answers. Ask "tell me about this project" and the reply
shows each step as it happens:

```
◆ Aporia · 14:48
  ✓ list files · 51 files
  ✓ read README.md · 264 lines
  … search "resolve_key" in lua
```

The tools are read-only: `list_files`, `grep` and `read_file`. They only
reach files inside the project root, never `.git/` or `.aporia/`, and never
files git ignores (`.env`, build output), so those are not sent to the
provider. An open buffer is read as it is in the editor, unsaved edits
included. A reply makes at most `backend.max_rounds` model calls (default 12);
the last one gets no tools and is told to answer from what it has read.

Teach mode gets no tools: it works from what you show it. Without the
backend, assist mode sees only what you stage.

## Window layout

The sidebar reserves a real column on the right, so your splits give way
instead of being covered. Layout plugins that pad or centre windows would
fight it:

- **no-neck-pain.nvim** is paused while the sidebar is open and resumed when
  it closes (only if aporia paused it). Opt out with
  `integrations = { no_neck_pain = false }`.
- Anything else: while the sidebar is open `vim.g.aporia_sidebar` is true,
  and the `User` events `AporiaSidebarOpen` / `AporiaSidebarClose` fire, so
  your own layout automation can hold off.

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
`:Aporia reset` start a fresh one; earlier sessions stay on disk, and
`/resume` (or `:Aporia resume`) picks one to continue, through
`vim.ui.select`, so your picker plugin shows the list. `/delete-all-sessions`
(or `:Aporia delete-all-sessions`) removes `.aporia/sessions/` after a
confirmation.

Two Neovims on the same project never overwrite each other: before saving,
aporia checks that the file is as it last saw it. If another instance wrote
it in the meantime, the conversation continues in a copy.

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
fetch gate, three-tier key resolution, streaming replies, read-only project
tools in assist mode (with the backend).
Not yet: LSP tools (symbols, references, diagnostics), a general fold
tree for the chat, treesitter scope expansion for selections, HTML-to-text
for fetched docs, vimdoc tag generation.

## Backend

aporia's agent core is moving into a Rust process (`backend/`) that Neovim
talks to over msgpack-RPC, one feature at a time; the Lua plugin keeps
working throughout. It needs a Rust toolchain to build:

```lua
{ "SimonJonsson/aporia.nvim", build = "make backend" }
```

`:checkhealth aporia` reports whether the binary is built and answering.
See `backend/README.md`.

## Development

```sh
make test        # plenary.busted
make test-rust   # cargo test in backend/
make backend     # cargo build --release in backend/
make lint        # selene + stylua --check (tools not bundled)
```

Requires: Neovim 0.10+, curl. No other runtime dependencies.
