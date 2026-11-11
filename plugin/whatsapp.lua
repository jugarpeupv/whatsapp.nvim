if vim.g.loaded_whatsapp then
  return
end
vim.g.loaded_whatsapp = true

local modes = { current = true, vertical = true, horizontal = true, tab = true }

local subcommands = {
  toggle = function() require("whatsapp").toggle() end,
  close = function() require("whatsapp").close() end,
  pair = function() require("whatsapp").pair() end,
  unlock = function() require("whatsapp").unlock() end,
  lock = function() require("whatsapp").lock() end,
  logout = function() require("whatsapp").logout() end,
  status = function() require("whatsapp").status() end,
  stop = function() require("whatsapp").stop() end,
  names = function() require("whatsapp").refresh_names() end,
}

vim.api.nvim_create_user_command("Whatsapp", function(cmd)
  local wa = require("whatsapp")
  if not require("whatsapp.state").opts then
    wa.setup()
  end
  local args = cmd.fargs
  if #args == 0 then
    return wa.open("current")
  end
  local sub = args[1]
  if sub == "open" then
    local mode = args[2] or "current"
    if not modes[mode] then
      vim.notify("Whatsapp: unknown open mode " .. mode, vim.log.levels.ERROR)
      return
    end
    return wa.open(mode)
  end
  if modes[sub] then
    return wa.open(sub)
  end
  if subcommands[sub] then
    return subcommands[sub]()
  end
  -- Anything else is a chat name: :Whatsapp Alice
  wa.open_by_name(table.concat(args, " "))
end, {
  nargs = "*",
  complete = function(lead)
    return vim.tbl_filter(function(s)
      return s:find(lead, 1, true) == 1
    end, vim.tbl_keys(vim.tbl_extend("force", subcommands, modes, { open = true })))
  end,
  desc = "Whatsapp in Neovim",
})
