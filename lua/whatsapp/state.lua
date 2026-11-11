-- Shared mutable state for the open Whatsapp pane and conversation.
local text = require("whatsapp.text")
local M = {
  opts = nil,
  chats = {},        -- array of chat rows from the bridge, newest first
  chat_by_jid = {},
  filter = "all",    -- chat list filter: all, unread or groups
  current = nil,     -- jid of the open conversation
  messages = {},     -- jid -> array of messages, oldest first
  drafts = {},      -- jid -> session-only compose buffer, reply and pending send
  tab = nil,
  mode = nil,        -- "current", "vertical", "horizontal" or "tab"
  single = false,    -- one pane shows list or conversation; no separate chat window
  previous = nil,    -- window/buffer/tab to restore when closing a single pane
  wins = { list = nil, chat = nil, compose = nil },
  bufs = { list = nil, chat = nil, compose = nil },
  chat_bufs = {},    -- jid -> listed conversation buffer
  status = { paired = nil, connected = false }, -- paired unknown until "ready"
  fatal = nil, -- why the bridge refused to start, shown on the splash
  replaced = false, -- another client took the session; no reconnect is coming
  synced = false,    -- offline sync finished for this bridge run
  sync = nil,        -- last sync.progress payload while history loads
  locked = false,    -- encrypted store closed; no bridge and no key in memory
  unlocking = false, -- an unlock request is waiting on GPG
  unlock_error = nil, -- why the last unlock failed, shown on the splash
  just_paired = false,
  help = false,      -- g? cheatsheet shown in the chat pane
  help_return = nil, -- window to focus again when the cheatsheet closes
  view = nil,        -- image message shown alone in the chat pane (zoom)
  qr = nil,          -- pairing QR lines while a pair.start is waiting for a scan
  pairing = false,   -- pair.start sent, QR code not here yet
  typing = nil,      -- { jid, sender, who, media } while the other party types in the open chat
  available = false, -- bridge asked to show this device online
  out_of_sync = {},  -- app state collections waiting on the phone's copy, name -> true
}

-- Columns available for text in a window, after number/sign columns the
-- user's config may force on.
function M.text_width(name, fallback)
  if not M.win_valid(name) then
    return fallback
  end
  local w = M.wins[name]
  local info = vim.fn.getwininfo(w)[1]
  return vim.api.nvim_win_get_width(w) - (info and info.textoff or 0)
end

-- What an out-of-sync app state collection stops syncing, in the user's
-- words. Only regular_low holds read marks; the rest hold pins, mutes,
-- contacts and the like.
function M.out_of_sync_label(name)
  if name == nil then
    if M.out_of_sync.regular_low then
      return "read marks"
    end
    return next(M.out_of_sync) and "chat settings" or nil
  end
  return name == "regular_low" and "read marks" or "chat settings"
end

function M.set_chats(chats)
  M.chats = chats
  M.chat_by_jid = {}
  for _, c in ipairs(chats) do
    M.chat_by_jid[c.jid] = c
  end
end

function M.chat_name(jid)
  local c = M.chat_by_jid[jid]
  return text.name(c and c.name or jid)
end

-- Chat and sender names come from remote users. Anything placed in a
-- statusline-style option must have "%" doubled, else "%{...}" would evaluate.
function M.bar_text(value)
  return (text.single_line(value):gsub("%%", "%%%%"))
end

-- Name plus phone number for direct chats, so a stranger whose push name
-- matches a contact is still distinguishable.
function M.chat_title(jid)
  local c = M.chat_by_jid[jid]
  local name = M.chat_name(jid)
  local user = jid:match("^([^@]+)@s%.whatsapp%.net$")
  if c and not c.is_group and user and user ~= name then
    return name .. "  +" .. user
  end
  return name
end

function M.layout_valid()
  if M.single then
    return M.win_valid("chat")
  end
  return M.tab and vim.api.nvim_tabpage_is_valid(M.tab) and M.win_valid("chat")
end

function M.win_valid(name)
  local w = M.wins[name]
  return w and vim.api.nvim_win_is_valid(w)
end

-- True when the named pane's window is actually displaying its buffer. In a
-- single-pane layout list and chat share a window, so only one is visible.
function M.jid_for_buf(buf)
  for jid, b in pairs(M.chat_bufs) do
    if b == buf then
      return jid
    end
  end
  return nil
end

function M.chat_visible(jid)
  local buf = M.chat_bufs[jid]
  if not buf then
    return false
  end
  return #vim.fn.win_findbuf(buf) > 0
end

function M.win_showing(name)
  if not M.win_valid(name) then
    return false
  end
  local buf = M.bufs[name]
  return buf ~= nil and vim.api.nvim_win_get_buf(M.wins[name]) == buf
end

function M.reset_layout()
  M.tab = nil
  M.mode = nil
  M.single = false
  M.previous = nil
  M.wins = { list = nil, chat = nil, compose = nil }
  -- Hidden buffers and per-chat drafts survive closing the pane.
end

return M
