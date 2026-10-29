vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
require("plenary.busted")
-- specs must never write .aporia/ into the repository
require("aporia.config").options.persist.enabled = false
-- specs stub aporia.http; backend_spec turns the backend on itself
require("aporia.config").options.backend.enabled = false
