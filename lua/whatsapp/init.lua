local client = require("whatsapp.client")
local S = require("whatsapp.state")
local list = require("whatsapp.ui.list")
local chat = require("whatsapp.ui.chat")
local compose = require("whatsapp.ui.compose")
local display = require("whatsapp.text")

local M = {}

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

local defaults = {
  bin = nil, -- defaults to <plugin>/bin/wa-bridge
  store = vim.fn.stdpath("data") .. "/whatsapp",
  list_width = 32,
  unread_count = false, -- show how many messages are unread, left of the time
  compose_height = 3,
  page_size = 100,
  notify = true,
  mark_read_on_view = true,
  default_reaction = "👍",
  list_height = 15, -- horizontal split height
  encryption = "none", -- "gpg" wraps the SQLCipher key with a GPG key
  gpg = {
    key = "", -- fingerprint; required for encryption = "gpg"
    program = nil, -- defaults to gpg in PATH
    key_file = nil, -- defaults to <store>/session.key.gpg
    home = nil, -- optional GNUPGHOME
  },
  lock_on_resume = true, -- lock after a long wall-clock jump (system suspend)
  lock_on_focus_lost = false, -- lock when the terminal/app loses focus
  images = {
    mode = "auto", -- "auto" | "tag" | "kitty", see docs/configuration.md
    max_width = 60, -- cells; pictures fill the bubble up to this
    max_height = 20, -- rows, also capped at half the pane
    crop = true, -- centre-crop pictures taller than max_height rather than shrink them
  },
}

local function define_highlights()
  local hl = function(name, opts)
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end
  hl("WhatsAppUnread", { bold = true })
  hl("WhatsAppFilter", { bold = true })
  hl("WhatsAppCurrent", { link = "Visual" })
  hl("WhatsAppTime", { link = "Comment" })
  hl("WhatsAppSender", { bold = true })
  hl("WhatsAppMe", { bold = true })
  hl("WhatsAppRead", { link = "DiagnosticInfo" })
  -- Underlined like a link: the tag responds to keys.
  local special = vim.api.nvim_get_hl(0, { name = "Special", link = false })
  hl("WhatsAppMedia", { fg = special.fg, underline = true })
  hl("WhatsAppSeparator", { link = "Comment" })
  hl("WhatsAppQuote", { link = "Comment" })
end

local function notify(msg, level)
  vim.notify("WhatsApp: " .. msg, level or vim.log.levels.INFO)
end

local function encrypted()
  return S.opts and S.opts.encryption == "gpg"
end

local function locked()
  return S.locked or (S.status and S.status.locked == true)
end

-- GPG options are not secrets: the fingerprint and the encrypted key file can
-- live in argv. The passphrase never leaves pinentry/gpg-agent.
local function bridge_args()
  if not encrypted() then
    return {}
  end
  local gpg = S.opts.gpg or {}
  local key = gpg.key
  if not key or key == "" then
    key = vim.env.WHATSAPP_GPG_FINGERPRINT
  end
  key = key and vim.trim(tostring(key)) or ""
  if key == "" then
    notify("encryption = 'gpg' needs gpg.key or WHATSAPP_GPG_FINGERPRINT", vim.log.levels.ERROR)
    return nil
  end
  local args = { "-encryption", "gpg", "-gpg-key", key }
  if gpg.program and gpg.program ~= "" then
    local program = vim.fn.exepath(gpg.program)
    table.insert(args, "-gpg-program")
    table.insert(args, program ~= "" and program or gpg.program)
  end
  if gpg.key_file and gpg.key_file ~= "" then
    table.insert(args, "-gpg-key-file")
    table.insert(args, gpg.key_file)
  end
  local home = gpg.home
  if not home or home == "" then
    home = vim.env.WHATSAPP_GPG_HOME
  end
  home = home and vim.fn.expand(vim.trim(tostring(home))) or ""
  if home ~= "" then
    table.insert(args, "-gpg-home")
    table.insert(args, home)
  end
  return args
end

-- Incoming-message notifications are coalesced into one line: several
-- echoes in one redraw would stack into a hit-enter prompt.
local pending = { count = 0, names = {}, seen = {}, timer = nil }

local function flush_notifications()
  pending.timer = nil
  local line = "WhatsApp ● " .. pending.count .. " new · " .. table.concat(pending.names, ", ")
  local max = math.max(20, vim.o.columns - 12)
  if vim.fn.strdisplaywidth(line) > max then
    line = display.fit(line, max - 1) .. "…"
  end
  pending.count, pending.names, pending.seen = 0, {}, {}
  vim.notify(line, vim.log.levels.INFO, { title = "WhatsApp" })
end

local function queue_notification(chat_name)
  chat_name = display.name(chat_name)
  pending.count = pending.count + 1
  if not pending.seen[chat_name] then
    pending.seen[chat_name] = true
    table.insert(pending.names, chat_name)
  end
  if not pending.timer then
    pending.timer = vim.defer_fn(flush_notifications, 300)
  end
end

-- Presence and typing -------------------------------------------------------

-- Online while a chat is open and the terminal is focused, like the phone
-- with a chat on screen. WhatsApp only sends typing notifications to
-- devices that are online.
local function set_presence(available)
  if S.available == available or not client.running() or locked() then
    return
  end
  S.available = available
  client.request("presence", { available = available }, function() end)
end

local typing_timer = nil
local resume_timer = nil
local focus_timer = nil
local help_back_list = false
local loading = {} -- jid -> true while a messages.list request is in flight
local winbar_text = {} -- window id -> text to show while it holds a Whatsapp buffer
local apply_win_opts

local WINBAR_EXPR = "%{v:lua.require'whatsapp'.render_winbar()}"

-- winbar is window-local, and Neovim copies it when splitting a window. Use
-- an expression instead of a literal so an inherited winbar renders empty as
-- soon as that window shows a normal buffer.
function M.set_winbar(win, text)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  winbar_text[win] = text or ""
  if vim.wo[win].winbar ~= WINBAR_EXPR then
    vim.wo[win].winbar = WINBAR_EXPR
  end
end

function M.render_winbar()
  local win = tonumber(vim.g.statusline_winid) or vim.api.nvim_get_current_win()
  if not win or win == 0 or not vim.api.nvim_win_is_valid(win) then
    return ""
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype
  if ft ~= "whatsapp" and ft ~= "whatsapp-chats" and ft ~= "whatsapp-compose" then
    return ""
  end
  return winbar_text[win] or ""
end

local function close_whatsapp_buffers()
  local seen = {}
  local function delete(buf)
    if buf and not seen[buf] and vim.api.nvim_buf_is_valid(buf) then
      seen[buf] = true
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  if S.win_valid("compose") then
    pcall(vim.api.nvim_win_close, S.wins.compose, true)
    S.wins.compose = nil
  end
  for _, buf in pairs(S.chat_bufs) do
    delete(buf)
  end
  for _, draft in pairs(S.drafts) do
    delete(draft.buf)
  end
  delete(S.bufs.chat)
  delete(S.bufs.list)
  delete(S.bufs.compose)
  pcall(function()
    require("whatsapp.ui.chat").close_buffers()
  end)
  S.chat_bufs = {}
  S.bufs = { list = nil, chat = nil, compose = nil }
  S.drafts = {}
end

local function stop_typing()
  if typing_timer then
    typing_timer:stop()
    typing_timer:close()
    typing_timer = nil
  end
  S.typing = nil
  chat.render_typing(false)
end

local function cancel_focus_lock()
  if focus_timer then
    focus_timer:stop()
    focus_timer:close()
    focus_timer = nil
  end
end

local function current_is_whatsapp()
  local ft = vim.bo[vim.api.nvim_get_current_buf()].filetype
  return ft == "whatsapp" or ft == "whatsapp-chats" or ft == "whatsapp-compose"
end

-- A short delay keeps pinentry and transient focus changes from locking the
-- store while a dialog is opening. Only lock if Whatsapp was actually the
-- buffer in use; losing focus from an unrelated file must not spawn the lock
-- screen.
local function schedule_focus_lock()
  cancel_focus_lock()
  if not (S.opts.lock_on_focus_lost and encrypted() and not locked()) then
    return
  end
  if S.unlocking or S.pairing or not client.running() then
    return
  end
  if not (S.status and S.status.paired == true) then
    return
  end
  -- Lock even if the user is looking at another file, but only bring up the
  -- locked splash when Whatsapp was the buffer in use.
  local show_locked = current_is_whatsapp()
  focus_timer = vim.defer_fn(function()
    focus_timer = nil
    if S.locked or S.unlocking or not client.running() then
      return
    end
    M.lock({ show = show_locked })
  end, 250)
end

local function start_typing(d)
  S.typing = { jid = d.chat, sender = d.sender, who = d.sender_name, media = d.media, since = vim.uv.now() }
  chat.render_typing(true)
  if not typing_timer then
    typing_timer = vim.uv.new_timer()
    typing_timer:start(0, 400, vim.schedule_wrap(function()
      -- WhatsApp sometimes never sends "paused"; drop a stale indicator.
      if not S.typing or vim.uv.now() - S.typing.since > 15000 then
        stop_typing()
        return
      end
      chat.render_typing(true)
    end))
  end
end

-- Bridge events ------------------------------------------------------------

local function wire_events()
  client.clear_listeners()
  client.on("ready", function(data)
    -- A ready event from a bridge that was stopped mid-unlock must not make
    -- the UI claim the store is open again.
    if S.locked and not S.unlocking then
      return
    end
    S.status = data
    S.locked = data.locked == true
    S.unlocking = false
    S.unlock_error = data.error
    S.fatal = nil
    S.replaced = false
    if S.locked and data.error then
      notify("store locked: " .. data.error, vim.log.levels.WARN)
    end
    if S.locked then
      M.show_chat()
    elseif not S.current then
      M.show_list()
    end
    chat.render()
    if not S.locked then
      M.refresh_chats()
    end
  end)
  client.on("unlocked", function(data)
    if S.locked and not S.unlocking then
      return
    end
    S.status = data
    S.locked = false
    S.unlocking = false
    S.unlock_error = nil
    if not S.current then
      M.show_list()
    end
    chat.render()
    M.refresh_chats()
  end)
  client.on("unpaired", function()
    S.status.paired = false
    chat.render()
    notify("not paired yet, run :Whatsapp pair", vim.log.levels.WARN)
  end)
  client.on("connected", function()
    if locked() then
      return
    end
    S.status.connected = true
    S.replaced = false
    chat.render()
    M.refresh_chats()
    -- Contacts may have synced after history on a previous run.
    client.request("names.refresh", nil, function() end)
  end)
  client.on("disconnected", function(d)
    S.status.connected = false
    if d and d.reason == "replaced" then
      S.replaced = true
      notify("another client took over this session, run :Whatsapp stop then :Whatsapp", vim.log.levels.WARN)
    end
    chat.render()
  end)
  client.on("logged_out", function(d)
    S.status.paired = false
    S.status.connected = false
    S.synced = false
    if d and d.reason == "user" then
      return
    end
    notify("logged out (" .. (d and d.reason or "?") .. "), run :Whatsapp pair", vim.log.levels.ERROR)
  end)
  client.on("pair.qr", function(d)
    S.pairing = false
    S.qr = d.lines
    if not S.layout_valid() then
      M.open()
    end
    M.show_chat(true)
    chat.render()
  end)
  local function end_pairing()
    S.pairing = false
    S.qr = nil
    M.show_list()
    chat.render()
  end
  client.on("pair.ok", function()
    end_pairing()
    S.status.paired = true
    S.just_paired = true
    notify("paired, syncing history")
  end)
  client.on("pair.timeout", function()
    end_pairing()
    notify("pairing timed out, run :Whatsapp pair again", vim.log.levels.WARN)
  end)
  client.on("pair.error", function(d)
    end_pairing()
    notify("pairing failed: " .. d.error, vim.log.levels.ERROR)
  end)
  client.on("sync.progress", function(d)
    S.sync = d
    if not S.current then
      chat.render()
    end
  end)
  client.on("sync.done", function()
    S.synced = true
    S.sync = nil
    if S.just_paired then
      S.just_paired = false
      notify("history synced")
    end
    chat.render()
  end)
  -- A collection waiting on the phone stops syncing until the phone answers,
  -- and nothing here can cure it, so say so rather than fail quietly.
  client.on("appstate.waiting", function(d)
    if not S.out_of_sync[d.name] then
      S.out_of_sync[d.name] = true
      notify(S.out_of_sync_label(d.name) .. " are out of sync, open WhatsApp on your phone to repair them", vim.log.levels.WARN)
    end
    chat.render()
  end)
  client.on("appstate.synced", function(d)
    if S.out_of_sync[d.name] then
      S.out_of_sync[d.name] = nil
      notify(S.out_of_sync_label(d.name) .. " back in sync")
    end
    chat.render()
  end)
  client.on("chats.changed", function()
    M.refresh_chats()
  end)
  client.on("typing", function(d)
    if locked() or d.chat ~= S.current then
      return
    end
    if d.state == "composing" then
      start_typing(d)
    else
      stop_typing()
    end
  end)
  client.on("messages.read", function(d)
    if locked() then
      return
    end
    local ids = {}
    for _, id in ipairs(d.ids or {}) do
      ids[id] = true
    end
    for _, m in ipairs(S.messages[d.chat] or {}) do
      if ids[m.id] then
        m.read = true
      end
    end
    local buf = S.chat_bufs[d.chat]
    if buf and #vim.fn.win_findbuf(buf) > 0 then
      chat.render({ buf = buf, jid = d.chat })
    end
  end)
  client.on("message", function(d)
    if locked() then
      return
    end
    local m = d.message
    if S.messages[m.chat_jid] then
      table.insert(S.messages[m.chat_jid], m)
    end
    if S.typing and S.typing.jid == m.chat_jid and S.typing.sender == m.sender then
      stop_typing()
    end
    local buf = S.chat_bufs[m.chat_jid]
    local visible = buf ~= nil and #vim.fn.win_findbuf(buf) > 0
    if visible then
      chat.render({ buf = buf, jid = m.chat_jid })
      if S.opts.mark_read_on_view and not m.from_me then
        client.request("chat.read", { jid = m.chat_jid })
      end
    elseif S.opts.notify and S.synced and not m.from_me then
      -- Messages replayed at startup are already marked unread in the list.
      queue_notification(d.chat_name)
    end
    M.refresh_chats()
  end)
  client.on("fatal", function(d)
    S.fatal = d.error
    notify(d.error, vim.log.levels.ERROR)
  end)
  client.on("exit", function(d)
    -- A refused start already explained itself through "fatal", and a lock
    -- stops the process on purpose.
    if d.code ~= 0 and not S.fatal and not S.locked then
      notify("bridge exited with code " .. d.code .. "\n" .. table.concat(d.stderr, "\n"), vim.log.levels.ERROR)
    end
    chat.render()
  end)
end

-- Data ---------------------------------------------------------------------

function M.refresh_names()
  if locked() or not client.running() then
    return
  end
  client.request("names.refresh", nil, function(err, res)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    notify("renamed " .. res.renamed .. " chats")
    M.refresh_chats()
    if S.current then
      M.open_chat(S.current)
    end
  end)
end

-- Set the unread flag on a chat, mirrored to the phone like the app's
-- "Mark as unread". Marking the open chat unread also closes it, otherwise
-- the next incoming message would read it again.
function M.set_unread(jid, unread)
  if locked() or not client.running() then
    return
  end
  local c = jid and S.chat_by_jid[jid]
  if not c then
    return
  end
  if not unread then
    c.unread = 0
    client.request("chat.read", { jid = jid })
  else
    c.unread = 1
    client.request("chat.unread", { jid = jid })
    if S.current == jid then
      M.show_list()
    end
  end
  list.render()
end

function M.toggle_unread(jid)
  local c = jid and S.chat_by_jid[jid]
  if c then
    M.set_unread(jid, c.unread == 0)
  end
end

-- Cycle focus list, chat, compose (when open), like Tab in diffview or
-- lazygit. dir is 1 or -1.
function M.focus_next(dir)
  local order, seen = {}, {}
  for _, name in ipairs({ "list", "chat", "compose" }) do
    local win = S.wins[name]
    if S.win_valid(name) and not seen[win] then
      seen[win] = true
      order[#order + 1] = win
    end
  end
  if #order == 0 then
    return
  end
  local cur = vim.api.nvim_get_current_win()
  local idx = 0
  for i, win in ipairs(order) do
    if win == cur then
      idx = i
    end
  end
  vim.api.nvim_set_current_win(order[((idx - 1 + dir) % #order) + 1])
end

function M.refresh_chats()
  if locked() or not client.running() then
    return
  end
  client.request("chats.list", nil, function(err, chats)
    if locked() then
      return
    end
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    S.set_chats(chats)
    if S.layout_valid() then
      list.render()
      -- The splash quotes chat and unread counts, so it is stale until the
      -- first list arrives.
      if not S.current then
        chat.render()
      end
    end
  end)
end

-- Help is a flag the chat pane renders over everything else, so any action
-- that gives the pane new content has to drop it first. Focus stays put:
-- the caller decides where the user ends up.
local function dismiss_help()
  S.help = false
  S.help_return = nil
end

local function load_messages(jid)
  if loading[jid] then
    return
  end
  loading[jid] = true
  client.request("messages.list", { jid = jid, limit = S.opts.page_size }, function(err, msgs)
    loading[jid] = nil
    if locked() then
      return
    end
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    -- A live message can land while this request is in flight; keep any
    -- the snapshot does not already contain.
    local seen = {}
    for _, m in ipairs(msgs) do
      seen[m.id] = true
    end
    for _, m in ipairs(S.messages[jid] or {}) do
      if not seen[m.id] and m.ts >= (msgs[#msgs] and msgs[#msgs].ts or 0) then
        table.insert(msgs, m)
      end
    end
    S.messages[jid] = msgs
    local buf = S.chat_bufs[jid]
    if buf and #vim.fn.win_findbuf(buf) > 0 then
      chat.render({ buf = buf, jid = jid })
      list.render()
      if S.current == jid then
        compose.update_winbar()
      end
    end
  end)
end

-- Entering a chat buffer from :b, a split, or the chat list updates the
-- plugin's notion of the open conversation and makes the buffer usable on
-- its own, without going through the Whatsapp pane.
function M.enter_chat(jid, buf, refresh)
  if not (jid and buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  if locked() then
    return
  end
  if S.current ~= jid then
    stop_typing()
  end
  S.current = jid
  S.bufs.chat = buf
  S.wins.chat = vim.api.nvim_get_current_win()
  apply_win_opts("chat")
  set_presence(true)
  if refresh or S.messages[jid] == nil then
    load_messages(jid)
  end
  chat.render({ buf = buf, jid = jid })
  list.render()
  local c = S.chat_by_jid[jid]
  if S.opts.mark_read_on_view and c and c.unread > 0 then
    c.unread = 0
    client.request("chat.read", { jid = jid })
  end
end

function M.open_chat(jid)
  if not jid then
    return
  end
  if locked() then
    notify("store is locked, run :Whatsapp unlock", vim.log.levels.WARN)
    return
  end
  dismiss_help()
  S.view = nil
  local buf = chat.ensure_buf(jid)
  if not buf then
    return
  end
  local target = S.layout_valid() and S.wins.chat or vim.api.nvim_get_current_win()
  S.wins.chat = target
  if S.single and S.wins.list == target then
    S.wins.list = target
  end
  vim.api.nvim_win_set_buf(target, buf)
  vim.api.nvim_set_current_win(target)
  M.enter_chat(jid, buf, true)
end

-- <C-v>/<C-s> in the list: open the conversation buffer in a new split,
-- keeping the list where it is. Reuse an existing extra split.
function M.open_chat_split(jid, vertical)
  if not jid then
    return
  end
  if locked() then
    notify("store is locked, run :Whatsapp unlock", vim.log.levels.WARN)
    return
  end
  if not S.layout_valid() then
    M.open()
  end
  if not S.layout_valid() then
    return
  end
  local buf = chat.ensure_buf(jid)
  if not buf then
    return
  end
  local win = S.split_win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    if vertical then
      vim.cmd("botright vsplit")
    else
      vim.cmd("botright split")
    end
    win = vim.api.nvim_get_current_win()
    S.split_win = win
  else
    vim.api.nvim_set_current_win(win)
  end
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_set_current_win(win)
  M.enter_chat(jid, buf, true)
end

function M.load_older()
  local jid = S.current
  local msgs = jid and S.messages[jid]
  if not msgs or #msgs == 0 then
    return
  end
  client.request("messages.list", { jid = jid, limit = S.opts.page_size, before = msgs[1].ts }, function(err, older)
    if err or not older or #older == 0 then
      notify("no older messages")
      return
    end
    for i = #older, 1, -1 do
      table.insert(msgs, 1, older[i])
    end
    local before = vim.api.nvim_buf_line_count(S.bufs.chat)
    chat.render()
    if S.win_valid("chat") then
      local after = vim.api.nvim_buf_line_count(S.bufs.chat)
      vim.api.nvim_win_set_cursor(S.wins.chat, { math.max(1, after - before), 0 })
    end
  end)
end

-- Actions ------------------------------------------------------------------

function M.send_compose(jid)
  if locked() or not client.running() then
    return
  end
  jid = jid or S.current
  if not jid then
    notify("no chat open", vim.log.levels.WARN)
    return
  end
  local draft = compose.draft(jid)
  if draft.sending then
    notify("this draft is already sending", vim.log.levels.WARN)
    return
  end
  local text = compose.text(jid)
  local buf = draft.buf
  if text == "" then
    vim.bo[buf].modified = false
    return
  end
  local params = { jid = jid, text = text }
  local reply = draft.reply_to
  if reply then
    params.reply_to = reply.id
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  draft.sending = true
  client.request("message.send", params, function(err, sent)
    draft.sending = false
    if locked() then
      return
    end
    if err then
      notify("send failed: " .. err, vim.log.levels.ERROR)
      return
    end
    -- Clear only the draft that was sent, and only if it has not been edited
    -- while awaiting the response. Other chats have independent buffers.
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_changedtick(buf) == tick then
      compose.clear(jid)
      if draft.reply_to == reply then draft.reply_to = nil end
    end
    if S.current == jid then compose.update_winbar() end
    if S.messages[sent.chat_jid] then
      table.insert(S.messages[sent.chat_jid], sent)
    end
    -- Replying moves the cursor up to the quoted message, so following only
    -- from the bottom would leave the sent message out of view.
    chat.render({ bottom = S.current == jid })
    M.close_compose()
    M.refresh_chats()
  end)
end

function M.reply_to(m)
  if not m or not S.current or m.chat_jid ~= S.current then
    return
  end
  compose.draft().reply_to = m
  compose.update_winbar()
  M.focus_compose()
end

function M.cancel_reply()
  local draft = compose.draft()
  if draft then draft.reply_to = nil end
  compose.update_winbar()
end

function M.react_to(m)
  if not m then
    return
  end
  vim.ui.input({ prompt = "Reaction (empty = " .. S.opts.default_reaction .. "): " }, function(emoji)
    if emoji == nil then
      return
    end
    if emoji == "" then
      emoji = S.opts.default_reaction
    end
    client.request("message.react", { jid = m.chat_jid, id = m.id, emoji = emoji }, function(err)
      if err then
        notify("reaction failed: " .. err, vim.log.levels.ERROR)
      end
    end)
  end)
end

local function fetch_media(m, then_do)
  if not m or not m.media_type or m.media_type == "" then
    return
  end
  notify((m.cached and "fetching " or "downloading ") .. m.media_type .. "…")
  client.request("media.download", { jid = m.chat_jid, id = m.id }, function(err, res)
    if err then
      notify("download failed: " .. err, vim.log.levels.ERROR)
      return
    end
    notify("saved to " .. res.path)
    m.path = res.path
    if not m.cached then
      m.cached = true
      if S.current == m.chat_jid then
        chat.render()
      end
    end
    if then_do then
      then_do(res.path)
    end
  end)
end

local function confirm_open(path)
  local choice = vim.fn.confirm("Open attachment in its default application?\n" .. path, "&Open\n&Cancel", 2)
  if choice == 1 then
    vim.ui.open(path)
  end
end

local function copy_path(path)
  vim.fn.setreg("+", path)
  vim.fn.setreg('"', path)
  notify("copied " .. path)
end

function M.download_media(m)
  fetch_media(m)
end

function M.open_media(m)
  if not m then
    return
  end
  if m.path then
    confirm_open(m.path)
  else
    fetch_media(m, confirm_open)
  end
end

-- Zoom: the picture takes over the chat pane, like help does, so nothing
-- is drawn twice. q, <Esc> or <CR> bring the conversation back.
function M.view_image(m)
  if not (m and m.path) or not S.win_valid("chat") then
    return
  end
  S.help = false
  S.view = m
  M.show_chat(true)
  chat.render()
end

function M.close_view()
  local m = S.view
  S.view = nil
  chat.render()
  local images = require("whatsapp.ui.images")
  images.release_full(m)
  images.repaint()
end

-- g? from any pane: the cheatsheet takes over the chat pane and focus
-- moves there so q closes it; closing returns focus to where you were.
function M.toggle_help()
  if S.help then
    S.help = false
    if S.single then
      if help_back_list then
        M.show_list()
      else
        M.show_chat(false)
      end
    end
    chat.render()
    if S.help_return and vim.api.nvim_win_is_valid(S.help_return) then
      vim.api.nvim_set_current_win(S.help_return)
    end
    S.help_return = nil
    require("whatsapp.ui.images").repaint()
    return
  end
  if not S.win_valid("chat") then
    return
  end
  help_back_list = S.single and S.win_showing("list") or not S.current
  S.help_return = vim.api.nvim_get_current_win()
  S.help = true
  S.view = nil
  M.show_chat(true)
  chat.render()
end

-- ]m / [m from any pane: focus the chat and move to the attachment. The
-- compose pane counts as the slot after the last one, so ]m past the end
-- returns you to writing and [m from compose lands on the newest media.
function M.next_media(dir)
  if not S.win_valid("chat") then
    return
  end
  local from_compose = S.win_valid("compose") and vim.api.nvim_get_current_win() == S.wins.compose
  vim.api.nvim_set_current_win(S.wins.chat)
  if chat.next_media(dir, from_compose) then
    return
  end
  if dir > 0 and S.win_valid("compose") then
    vim.api.nvim_set_current_win(S.wins.compose)
    if not from_compose then
      return
    end
  end
  notify("no more media")
end

-- <CR> on media: one menu, so the only thing to learn is that <CR> acts on
-- the attachment. The target is the media under the cursor, else the
-- newest in the chat.
function M.media_menu(m)
  if not m then
    return
  end
  local items = {}
  local images = require("whatsapp.ui.images")
  -- Zoom first, so <CR><CR> on a picture is the quick look.
  if m.media_type == "image" and images.mode() == "kitty" then
    items[#items + 1] = { "View", function()
      if m.path then
        M.view_image(m)
      else
        fetch_media(m, function() M.view_image(m) end)
      end
    end }
  end
  if not m.cached then
    items[#items + 1] = { "Download", function() fetch_media(m) end }
  end
  items[#items + 1] = { "Open  gx", function() M.open_media(m) end }
  items[#items + 1] = { "Copy path", function()
    if m.path then
      copy_path(m.path)
    else
      fetch_media(m, copy_path)
    end
  end }
  -- Navigation lives in the menu too, so the first <CR> teaches ]m [m.
  if chat.media_count() > 1 then
    items[#items + 1] = { "Next media  ]m", function() M.next_media(1) end }
    items[#items + 1] = { "Previous media  [m", function() M.next_media(-1) end }
  end
  vim.ui.select(items, {
    prompt = (m.media_type or "media") .. (m.filename and m.filename ~= "" and (" " .. m.filename) or ""),
    format_item = function(item) return item[1] end,
  }, function(item)
    if item then
      item[2]()
    end
  end)
end

function M.focus_compose(jid)
  M.ensure_compose(jid)
  if not S.win_valid("compose") then
    return
  end
  vim.api.nvim_set_current_win(S.wins.compose)
  vim.cmd("startinsert")
end

-- Layout -------------------------------------------------------------------

-- Window-local options for each pane. Applied when the pane is created and
-- again after the events user configs commonly hook to toggle number
-- options (window switch, insert mode, terminal focus). Plugin autocmds are
-- defined after the user's, so they run last and win.
local common = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  cursorline = false,
  wrap = true,
  linebreak = false,
  winfixwidth = false,
  winfixheight = false,
}
local WIN_OPTS = {
  list = vim.tbl_extend("force", common, { cursorline = true, wrap = false, winfixwidth = true }),
  chat = vim.tbl_extend("force", common, { wrap = true, linebreak = true }),
  compose = vim.tbl_extend("force", common, { winfixheight = true }),
}

-- Neovim keeps window-option values per buffer, so setting wrap/number on a
-- Whatsapp buffer does not leak when an existing user buffer returns to that
-- window. A brand-new buffer does inherit the current window values, though;
-- remember new buffers and reset those inherited options on entry.
local new_buffers = {}
local base_win_opts = {}

local function pane_for_buf(buf)
  local ft = vim.bo[buf].filetype
  if ft == "whatsapp-chats" then
    return "list"
  elseif ft == "whatsapp-compose" then
    return "compose"
  elseif ft == "whatsapp" then
    return "chat"
  end
end

local function capture_base_opts(win)
  base_win_opts = {}
  for _, spec in pairs(WIN_OPTS) do
    for k in pairs(spec) do
      local ok, value = pcall(function()
        return vim.wo[win][k]
      end)
      if ok then
        base_win_opts[k] = value
      end
    end
  end
  base_win_opts.winbar = vim.wo[win].winbar
end

local function reset_inherited_opts(win)
  for k, value in pairs(base_win_opts) do
    vim.wo[win][k] = value
  end
end

-- Apply the right pane options to whatever window shows a Whatsapp buffer,
-- including buffers opened directly with :buffer. New non-Whatsapp buffers
-- get global defaults instead of inheriting the previous pane's options.
local function apply_buffer_opts(win, buf)
  local name = pane_for_buf(buf)
  if name then
    for k, v in pairs(WIN_OPTS[name]) do
      vim.wo[win][k] = v
    end
    return
  end
  if new_buffers[buf] then
    new_buffers[buf] = nil
    reset_inherited_opts(win)
  end
end

apply_win_opts = function(name)
  if not S.win_showing(name) then
    return
  end
  for k, v in pairs(WIN_OPTS[name]) do
    vim.wo[S.wins[name]][k] = v
  end
  -- A wrapped QR code cannot be scanned; let it run off the edge instead.
  if name == "chat" and S.qr then
    vim.wo[S.wins.chat].wrap = false
  end
end

-- The compose pane only exists after S in a conversation; nothing to write
-- to before that.
function M.ensure_compose(jid)
  jid = jid or S.current
  if not jid or not S.win_valid("chat") then
    return
  end
  if S.current ~= jid then
    S.current = jid
  end
  local buf = compose.ensure_buf(jid)
  S.bufs.compose = buf
  if S.win_valid("compose") then
    vim.api.nvim_win_set_buf(S.wins.compose, buf)
  else
    S.wins.compose = vim.api.nvim_open_win(buf, false, {
      split = "below",
      win = S.wins.chat,
      height = S.opts.compose_height,
    })
  end
  apply_win_opts("compose")
  compose.update_winbar()
end

function M.close_compose()
  if S.win_valid("compose") then
    vim.api.nvim_win_close(S.wins.compose, true)
    S.wins.compose = nil
  end
  M.cancel_reply()
  if S.win_valid("chat") then
    vim.api.nvim_set_current_win(S.wins.chat)
    apply_win_opts("chat")
  end
end

-- Show the conversation buffer. In single-pane layouts the same window
-- switches from the chat list to the conversation.
function M.show_chat(focus)
  if not S.layout_valid() then
    return
  end
  local buf = S.current and chat.ensure_buf(S.current) or chat.splash_buf()
  S.bufs.chat = buf
  if S.single then
    S.wins.list = S.wins.chat
  end
  vim.api.nvim_win_set_buf(S.wins.chat, buf)
  apply_win_opts("chat")
  if focus then
    vim.api.nvim_set_current_win(S.wins.chat)
  end
end

-- Show the chat list. In a tab layout the list and chat are separate, so the
-- chat pane goes back to its splash; in a single pane the window switches
-- back to the list buffer.
function M.show_list()
  if not S.layout_valid() then
    return
  end
  dismiss_help()
  S.view = nil
  stop_typing()
  set_presence(false)
  S.current = nil
  if S.win_valid("compose") then
    vim.api.nvim_win_close(S.wins.compose, true)
    S.wins.compose = nil
  end
  local buf = list.ensure_buf()
  S.bufs.list = buf
  if S.split_win and vim.api.nvim_win_is_valid(S.split_win)
    and S.wins.list and S.wins.list ~= S.split_win then
    -- An extra conversation split exists: show the list in its own window
    -- and leave the split alone.
    vim.api.nvim_win_set_buf(S.wins.list, buf)
    apply_win_opts("list")
    vim.api.nvim_set_current_win(S.wins.list)
    list.render()
    return
  end
  S.bufs.chat = chat.splash_buf()
  if S.single then
    S.wins.list = S.wins.chat
    vim.api.nvim_win_set_buf(S.wins.chat, buf)
    apply_win_opts("list")
    vim.api.nvim_set_current_win(S.wins.chat)
  else
    vim.api.nvim_win_set_buf(S.wins.list, buf)
    apply_win_opts("list")
    vim.api.nvim_set_current_win(S.wins.list)
    vim.api.nvim_win_set_buf(S.wins.chat, S.bufs.chat)
    apply_win_opts("chat")
    chat.render()
  end
  list.render()
end

-- q in a conversation: return to the list when the chat is part of the
-- Whatsapp pane, otherwise close the standalone window (:b opened it).
function M.close_chat(jid)
  jid = jid or S.current
  local buf = jid and S.chat_bufs[jid]
  if not buf then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if S.split_win == win then
    pcall(vim.api.nvim_win_close, win, true)
    S.split_win = nil
    S.wins.chat = S.pane_chat_win
    if not (S.wins.chat and vim.api.nvim_win_is_valid(S.wins.chat)) then
      S.wins.chat = S.wins.list
    end
    S.current = nil
    if S.wins.chat and vim.api.nvim_win_is_valid(S.wins.chat) then
      S.bufs.chat = chat.splash_buf()
      vim.api.nvim_win_set_buf(S.wins.chat, S.bufs.chat)
    end
    M.show_list()
    return
  end
  if S.layout_valid() and S.wins.chat == win then
    M.show_list()
    return
  end
  if vim.api.nvim_win_get_buf(win) == buf then
    if #vim.api.nvim_tabpage_list_wins(0) > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    else
      pcall(vim.cmd, "bprevious")
    end
  end
end

local function remember_previous()
  S.previous = {
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_win_get_buf(0),
    tab = vim.api.nvim_get_current_tabpage(),
  }
end

local function layout_autocmds(mode)
  local group = vim.api.nvim_create_augroup("WhatsappLayout", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "InsertEnter", "InsertLeave", "FocusGained", "FocusLost" }, {
    group = group,
    callback = function(ev)
      apply_buffer_opts(vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf())
      if ev.event == "FocusLost" then
        set_presence(false)
        schedule_focus_lock()
      elseif ev.event == "FocusGained" then
        cancel_focus_lock()
        if S.current and S.layout_valid() then
          set_presence(true)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      if S.layout_valid() then
        chat.render()
        list.render()
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      winbar_text[tonumber(ev.match)] = nil
    end,
  })
  if mode == "tab" then
    vim.api.nvim_create_autocmd("TabClosed", {
      group = group,
      callback = function()
        if not S.layout_valid() then
          S.reset_layout()
        end
      end,
    })
  end
end

local function build_layout(mode)
  capture_base_opts(vim.api.nvim_get_current_win())
  remember_previous()
  S.mode = mode
  S.single = mode ~= "tab"
  S.tab = mode == "tab" and vim.api.nvim_get_current_tabpage() or nil
  S.current = nil

  if mode == "tab" then
    vim.cmd("tabnew")
    S.tab = vim.api.nvim_get_current_tabpage()
    S.wins.chat = vim.api.nvim_get_current_win()
    S.pane_chat_win = S.wins.chat
    S.wins.list = nil
    S.bufs.chat = chat.splash_buf()
    vim.api.nvim_win_set_buf(S.wins.chat, S.bufs.chat)
    apply_win_opts("chat")

    vim.cmd("topleft " .. S.opts.list_width .. "vsplit")
    S.wins.list = vim.api.nvim_get_current_win()
    S.bufs.list = list.ensure_buf()
    vim.api.nvim_win_set_buf(S.wins.list, S.bufs.list)
    apply_win_opts("list")
  else
    if mode == "vertical" then
      vim.cmd("botright " .. S.opts.list_width .. "vsplit")
    elseif mode == "horizontal" then
      vim.cmd("botright " .. S.opts.list_height .. "split")
    end
    S.wins.chat = vim.api.nvim_get_current_win()
    S.pane_chat_win = S.wins.chat
    S.wins.list = S.wins.chat
    vim.api.nvim_win_set_buf(S.wins.chat, list.ensure_buf())
    S.bufs.list = list.ensure_buf()
    S.bufs.chat = chat.splash_buf()
    apply_win_opts("list")
  end

  layout_autocmds(mode)
  list.render()
  chat.render()
end

function M.open(mode)
  mode = mode or "current"
  if mode ~= "current" and mode ~= "vertical" and mode ~= "horizontal" and mode ~= "tab" then
    notify("unknown open mode " .. mode, vim.log.levels.WARN)
    mode = "current"
  end
  if not client.running() then
    local args = bridge_args()
    if args == nil then
      return
    end
    wire_events()
    -- Fresh bridge, fresh status: a stale "connected" would skip the
    -- connecting splash.
    S.status = { paired = nil, connected = false, locked = S.locked, encrypted = encrypted() }
    S.out_of_sync = {}
    S.synced = false
    S.sync = nil
    S.unlock_error = nil
    if S.locked then
      if encrypted() then
        S.unlocking = true
      else
        S.locked = false
        S.status.locked = false
      end
    end
    if not client.start(S.opts.bin, S.opts.store, args) then
      S.unlocking = false
      return
    end
  end
  if S.layout_valid() then
    if S.mode == "tab" then
      vim.api.nvim_set_current_tabpage(S.tab)
    end
    -- :Whatsapp is the "show me the chat list" command. Do not leave the
    -- previous conversation buffer in front just because it is still open.
    if locked() then
      M.show_chat(true)
    else
      M.show_list()
    end
    return
  end
  build_layout(mode)
  if locked() then
    M.show_chat(true)
  else
    M.show_list()
  end
  M.refresh_chats()
end

function M.toggle()
  if S.layout_valid() then
    M.close()
  else
    M.open("current")
  end
end

function M.close()
  dismiss_help()
  S.view = nil
  require("whatsapp.ui.images").reset()
  stop_typing()
  set_presence(false)
  if S.split_win and vim.api.nvim_win_is_valid(S.split_win) then
    pcall(vim.api.nvim_win_close, S.split_win, true)
    S.split_win = nil
    S.wins.chat = S.pane_chat_win or S.wins.list
  end
  local prev = S.previous
  if S.layout_valid() then
    if S.mode == "tab" then
      pcall(vim.api.nvim_set_current_tabpage, S.tab)
      pcall(vim.cmd, "tabclose")
    elseif S.wins.chat and vim.api.nvim_win_is_valid(S.wins.chat) then
      if S.mode == "current" then
        if prev and prev.buf and vim.api.nvim_buf_is_valid(prev.buf) then
          pcall(vim.api.nvim_win_set_buf, S.wins.chat, prev.buf)
        end
      else
        pcall(vim.api.nvim_win_close, S.wins.chat, true)
        if prev and prev.win and vim.api.nvim_win_is_valid(prev.win) then
          pcall(vim.api.nvim_set_current_win, prev.win)
        end
      end
    end
  end
  S.reset_layout()
end

function M.stop()
  M.close()
  S.available = false
  S.locked = encrypted()
  S.unlocking = false
  client.stop()
  notify("bridge stopped")
end

-- Lock hides the conversation, stops the bridge, and drops the SQLCipher key
-- with the process. Whatever is on disk stays encrypted.
function M.lock(opts)
  local show = not opts or opts.show ~= false
  cancel_focus_lock()
  local was_running = client.running()
  S.available = false
  S.locked = true
  S.unlocking = false
  S.unlock_error = nil
  S.status = { paired = nil, connected = false, locked = true, encrypted = encrypted() }
  S.fatal = nil
  S.replaced = false
  S.current = nil
  S.messages = {}
  S.chats = {}
  S.chat_by_jid = {}
  if S.split_win and vim.api.nvim_win_is_valid(S.split_win) then
    pcall(vim.api.nvim_win_close, S.split_win, true)
    S.split_win = nil
    S.wins.chat = S.pane_chat_win or S.wins.list
  end
  close_whatsapp_buffers()
  S.qr = nil
  S.pairing = false
  S.help = false
  S.help_return = nil
  S.view = nil
  S.synced = false
  S.sync = nil
  S.out_of_sync = {}
  stop_typing()
  client.stop()
  if show and S.layout_valid() then
    M.show_chat(true)
    chat.render()
  end
  if was_running then
    notify("locked")
  end
end

function M.unlock()
  if not client.running() then
    M.open()
    return
  end
  if not locked() then
    M.open()
    return
  end
  if S.unlocking then
    notify("already waiting for GPG")
    return
  end
  S.unlocking = true
  S.unlock_error = nil
  M.show_chat(true)
  chat.render()
  notify("unlocking with GPG…")
  client.request("unlock", nil, function(err, st)
    S.unlocking = false
    if err then
      S.locked = true
      S.unlock_error = err
      notify("unlock failed: " .. err, vim.log.levels.ERROR)
    else
      S.locked = false
      S.status = st or S.status
      S.unlock_error = nil
      M.refresh_chats()
    end
    chat.render()
  end)
end

-- The QR code renders in the chat pane, so pairing opens the view first.
function M.pair()
  M.open()
  if not client.running() then
    return
  end
  if locked() then
    notify("store is locked, run :Whatsapp unlock", vim.log.levels.WARN)
    return
  end
  dismiss_help()
  S.pairing = true
  M.show_chat(true)
  chat.render()
  client.request("pair.start", nil, function(err)
    if err then
      S.pairing = false
      chat.render()
      notify(err, vim.log.levels.WARN)
    end
  end)
end

-- Unlink this device from the phone and forget the local session. Stops the
-- bridge so the next :Whatsapp pair starts with a clean device store.
function M.logout()
  if not client.running() then
    notify("bridge not running")
    return
  end
  client.request("logout", nil, function(err)
    M.close()
    close_whatsapp_buffers()
    client.stop()
    S.status.paired = false
    S.status.connected = false
    S.synced = false
    if err then
      notify(err, vim.log.levels.WARN)
    end
    notify("logged out, run :Whatsapp pair to link again")
  end)
end

function M.status()
  if not client.running() then
    notify("bridge not running")
    return
  end
  if locked() then
    notify(vim.inspect(S.status))
    return
  end
  client.request("status", nil, function(err, st)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    notify(vim.inspect(st))
  end)
end

function M.open_by_name(name)
  M.open()
  if locked() then
    notify("store is locked, run :Whatsapp unlock", vim.log.levels.WARN)
    return
  end
  local needle = name:lower()
  local function try()
    for _, c in ipairs(S.chats) do
      if c.name:lower():find(needle, 1, true) then
        M.open_chat(c.jid)
        return true
      end
    end
    return false
  end
  if not try() then
    client.request("chats.list", nil, function(_, chats)
      if chats then
        S.set_chats(chats)
        list.render()
        if not try() then
          notify("no chat matching " .. name, vim.log.levels.WARN)
        end
      end
    end)
  end
end

function M.setup(opts)
  if not next(base_win_opts) then
    for _, spec in pairs(WIN_OPTS) do
      for k in pairs(spec) do
        local ok, value = pcall(function()
          return vim.wo[0][k]
        end)
        if ok then
          base_win_opts[k] = value
        end
      end
    end
    base_win_opts.winbar = vim.wo[0].winbar
  end
  S.opts = vim.tbl_deep_extend("force", defaults, opts or {})
  S.opts.bin = S.opts.bin or (plugin_root() .. "/bin/wa-bridge")
  if type(S.opts.gpg) ~= "table" then
    S.opts.gpg = vim.deepcopy(defaults.gpg)
  end
  if S.opts.encryption == "gpg" and (not S.opts.gpg.program or S.opts.gpg.program == "") then
    -- Neovim launched from a GUI can have a PATH without Homebrew. Resolve
    -- the absolute path here rather than relying on the child's environment.
    local gpg = vim.fn.exepath("gpg")
    if gpg ~= "" then
      S.opts.gpg.program = gpg
    end
  end
  define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = define_highlights })
  -- Exiting Neovim ends the bridge; SQLCipher has already written ciphertext,
  -- so there is nothing to encrypt on the way out.
  vim.api.nvim_create_autocmd("VimLeavePre", { callback = client.stop })
  -- New buffers inherit the current window's local options. Mark them so the
  -- BufEnter handler can put global defaults back if they are not ours.
  vim.api.nvim_create_autocmd("BufNew", {
    callback = function(ev)
      new_buffers[ev.buf] = true
    end,
  })

  -- Neovim cannot see the OS suspend event. A timer that wakes with a large
  -- wall-clock gap is the portable signal: sleep/resume leaves a jump the
  -- monotonic clock does not necessarily show. Lock after the resume, which
  -- keeps the key out of the new session even though it was in RAM during
  -- suspend.
  if resume_timer then
    resume_timer:stop()
    resume_timer:close()
    resume_timer = nil
  end
  if S.opts.lock_on_resume then
    local last = os.time()
    resume_timer = vim.uv.new_timer()
    resume_timer:start(30000, 30000, vim.schedule_wrap(function()
      local now = os.time()
      local gap = now - last
      last = now
      if gap > 120 and encrypted() and client.running() and not S.locked then
        M.lock()
      end
    end))
  end
end

return M
