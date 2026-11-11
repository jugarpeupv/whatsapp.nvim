-- Some Neovim development builds ship without the vim.log module; the tests
-- only need its levels table.
if rawget(vim, "log") == nil then
  rawset(vim, "log", { levels = { TRACE = 0, DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4, OFF = 5 } })
end

-- Minimal runtime for headless tests: plugin on the path, nothing else.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
vim.g.whatsapp_test_root = root
