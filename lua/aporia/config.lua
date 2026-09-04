local M = {}

M.defaults = {
  provider = "baseten",
  providers = {
    baseten = {
      base_url = "https://inference.baseten.co/v1",
      model = "",
      api_key_env = "BASETEN_API_KEY",
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
  mappings = {
    question = "<leader>aq",
    hint = "<leader>ah",
    reframe = "<leader>ar",
    steps = "<leader>as",
    rootcause = "<leader>ac",
    log = "<leader>al",
    toggle = "<leader>at",
    add_selection = "<leader>aa",
    add_buffer = "<leader>ab",
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

return M
