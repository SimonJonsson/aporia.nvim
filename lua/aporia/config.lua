local M = {}

M.defaults = {
  provider = "baseten",
  providers = {
    baseten = {
      base_url = "https://inference.baseten.co/v1",
      model = "",
      api_key_env = "BASETEN_API_KEY",
      api_key_cmd = "secret-tool lookup service baseten",
    },
    ninfer = {
      base_url = "http://localhost:8000/v1",
      model = "",
      api_key_env = "",
    },
    openai = {
      base_url = "https://api.openai.com/v1",
      model = "",
      api_key_env = "OPENAI_API_KEY",
    },
  },
  log_file = vim.fn.expand("~/notes/learning.md"),
  fetch = {
    mode = "confirm",
    max_fetches_per_turn = 2,
  },
  context = {
    padding = 15,
    max_lines = 200,
  },
  window = {
    position = "right",
    width = 0.4,
  },
  -- conversations saved under <root>/<dir>, root found by markers from cwd;
  -- no root means nothing is saved
  persist = {
    enabled = true,
    dir = ".aporia",
    markers = { ".aporia", ".git" },
  },
  -- the Rust backend (backend/, built with `make backend`) runs the agent
  -- loop and gives assist mode tools to read the project; without a built
  -- binary aporia chats without tools
  backend = {
    enabled = true,
    cmd = nil, -- default: the newest of backend/target/{release,debug}/aporia
    max_rounds = 12, -- model calls per reply; the last one gets no tools
  },
  -- window-layout plugins aporia steps around while the sidebar is open
  integrations = {
    no_neck_pain = true, -- paused while open, resumed on close
  },
  -- prefix labels in which-key (v3+); false to skip
  which_key_groups = {
    ["<leader>a"] = "aporia assist",
    ["<leader>t"] = "aporia teach",
  },
  mappings = {
    question = "<leader>tq",
    hint = "<leader>th",
    reframe = "<leader>tr",
    steps = "<leader>ts",
    rootcause = "<leader>tc",
    log = "<leader>tl",
    toggle = "<leader>at",
    toggle_teach = "<leader>tt",
    add_selection = "<leader>aa",
    add_buffer = "<leader>ab",
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

return M
