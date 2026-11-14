local S = require("whatsapp.state")
local format = require("whatsapp.format")
local text = require("whatsapp.text")
local help = require("whatsapp.ui.help")
local images = require("whatsapp.ui.images")

local M = {}
local ns = vim.api.nvim_create_namespace("whatsapp_chat")
local ns_hint = vim.api.nvim_create_namespace("whatsapp_chat_hint")
local typing_frame = 0
local states = {} -- buffer -> per-conversation render state
local splash_buf = nil

local function st(buf)
  if not states[buf] then
    states[buf] = {
      jid = S.jid_for_buf(buf),
      line_owner = {},
      media_rows = {},
      typing_start = nil,
      rendered_jid = nil,
    }
  end
  return states[buf]
end

local function chat_buf()
  if S.bufs.chat and vim.api.nvim_buf_is_valid(S.bufs.chat) then
    return S.bufs.chat
  end
  return vim.api.nvim_get_current_buf()
end

local function chat_state()
  return st(chat_buf())
end

-- Rows for the typing indicator in the open chat, nil when there is none.
local function typing_rows(jid)
  local t = S.typing
  if not t or not jid or t.jid ~= jid or S.qr or S.help or S.view then
    return nil
  end
  return { "  " .. format.typing_line(t.who, typing_frame, t.media) }
end

-- A readable, unique buffer name. Spaces and punctuation collapse to dashes,
-- groups get a prefix, and a short hash breaks collisions between contacts.
local function buffer_name(jid)
  local c = S.chat_by_jid[jid]
  local label = c and c.name ~= "" and c.name or (jid or "chat"):match("^([^@]+)")
  local slug = text.name(label or "chat"):lower()
    :gsub("%s+", "-")
    :gsub("[^%w%-%._\128-\255]", "")
    :gsub("%-+", "-")
    :gsub("^%-+", "")
    :gsub("%-+$", "")
  if slug == "" then
    slug = "chat"
  end
  slug = slug:sub(1, 48)
  if c and c.is_group then
    slug = "group-" .. slug
  end
  local name = "whatsapp://" .. slug
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and existing ~= S.chat_bufs[jid] then
    name = name .. "-" .. vim.fn.sha256(jid):sub(1, 6)
  end
  return name
end

function M.buffer_name(jid)
  return buffer_name(jid)
end

function M.ensure_buf(jid)
  jid = jid or S.current
  if not jid then
    return nil
  end
  local existing = S.chat_bufs[jid]
  if existing and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, buffer_name(jid))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = true
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "whatsapp"
  vim.bo[buf].modifiable = false
  S.chat_bufs[jid] = buf
  st(buf).jid = jid

  local wa = require("whatsapp")
  local map = function(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    buffer = buf,
    callback = function()
      wa.enter_chat(jid, buf)
    end,
  })
  map("S", function() wa.focus_compose(jid) end, "Write a message")
  map("R", function() wa.reply_to(M.message_under_cursor()) end, "Reply to message")
  map("r", function() wa.react_to(M.message_under_cursor()) end, "React to message")
  map("<CR>", function()
    if S.view then
      wa.close_view()
    else
      wa.media_menu(M.media_target())
    end
  end, "Media menu, or close the picture")
  map("gx", function() wa.open_media(M.media_target()) end, "Open media")
  map("]m", function() wa.next_media(1) end, "Next media")
  map("[m", function() wa.next_media(-1) end, "Previous media")
  map("K", wa.load_older, "Load older messages")
  map("~", function() wa.toggle_unread(jid) end, "Toggle unread")
  map("gU", function() wa.set_unread(jid, true) end, "Mark chat unread and close it")
  map("gu", function() wa.set_unread(jid, false) end, "Mark chat read")
  map("<Tab>", function() wa.focus_next(1) end, "Next pane")
  map("<S-Tab>", function() wa.focus_next(-1) end, "Previous pane")
  map("q", function()
    if S.help then
      wa.toggle_help()
    elseif S.view then
      wa.close_view()
    else
      wa.close_chat(jid)
    end
  end, "Close help or picture, or back to chats")
  map("<Esc>", function()
    if S.help then
      wa.toggle_help()
    elseif S.view then
      wa.close_view()
    end
  end, "Close help or picture")
  map("g?", wa.toggle_help, "All keys")
  vim.api.nvim_create_autocmd("CursorMoved", { buffer = buf, callback = M.update_hint })
  return buf
end

-- The list/chat pane needs a buffer for the splash when no conversation is
-- open. It is deliberately unlisted: there is nothing to return to.
function M.splash_buf()
  if splash_buf and vim.api.nvim_buf_is_valid(splash_buf) then
    return splash_buf
  end
  splash_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(splash_buf, "whatsapp://splash")
  vim.bo[splash_buf].buftype = "nofile"
  vim.bo[splash_buf].bufhidden = "hide"
  vim.bo[splash_buf].buflisted = false
  vim.bo[splash_buf].swapfile = false
  vim.bo[splash_buf].filetype = "whatsapp"
  vim.bo[splash_buf].modifiable = false
  states[splash_buf] = { jid = nil, line_owner = {}, media_rows = {}, typing_start = nil, rendered_jid = nil }
  local wa = require("whatsapp")
  vim.keymap.set("n", "q", wa.close, { buffer = splash_buf, silent = true, desc = "Close Whatsapp" })
  vim.keymap.set("n", "g?", wa.toggle_help, { buffer = splash_buf, silent = true, desc = "All keys" })
  return splash_buf
end

function M.close_buffers()
  if splash_buf and vim.api.nvim_buf_is_valid(splash_buf) then
    pcall(vim.api.nvim_buf_delete, splash_buf, { force = true })
  end
  splash_buf = nil
  states = {}
end

function M.media_count()
  return #chat_state().media_rows
end

-- The attachment that <CR> and gx act on: the media message under the
-- cursor, else the newest one in the chat. Returns message and its tag row.
function M.media_target()
  local state = chat_state()
  local rows = state.media_rows
  if #rows == 0 then
    return nil
  end
  if S.win_showing("chat") then
    local row = vim.api.nvim_win_get_cursor(S.wins.chat)[1]
    local m = state.line_owner[row]
    if m and m.media_type and m.media_type ~= "" then
      for _, e in ipairs(rows) do
        if e.m == m then
          return m, e.row
        end
      end
    end
  end
  local last = rows[#rows]
  return last.m, last.row
end

-- ]m / [m: move the cursor to the next or previous attachment, counting
-- from the cursor, or from before the first / after the last row when
-- from_edge is set. Returns false when there is none that way so the
-- caller can fall through.
function M.next_media(dir, from_edge)
  if not S.win_valid("chat") then
    return false
  end
  local state = chat_state()
  local rows = state.media_rows
  if #rows == 0 then
    vim.notify("WhatsApp: no media in this chat", vim.log.levels.INFO)
    return false
  end
  local row, cur
  if from_edge then
    row = dir > 0 and 0 or vim.api.nvim_buf_line_count(S.bufs.chat) + 1
  else
    row = vim.api.nvim_win_get_cursor(S.wins.chat)[1]
    cur = state.line_owner[row]
  end
  local target
  if dir > 0 then
    for _, e in ipairs(rows) do
      if e.row > row and e.m ~= cur then
        target = e
        break
      end
    end
  else
    for i = #rows, 1, -1 do
      local e = rows[i]
      if e.row < row and e.m ~= cur then
        target = e
        break
      end
    end
  end
  if not target then
    return false
  end
  vim.api.nvim_win_set_cursor(S.wins.chat, { target.row, 0 })
  M.update_hint()
  return true
end

-- Keys are not discoverable from the tag alone, so the target attachment
-- carries a hint on a virtual line under its message: keys in Special,
-- words in Comment, like the splash. Its own line, so it never wraps into
-- the message text.
function M.update_hint()
  local buf = S.bufs.chat
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns_hint, 0, -1)
  local m, row = M.media_target()
  if not m then
    return
  end
  local entry
  for _, e in ipairs(st(buf).media_rows) do
    if e.m == m then
      entry = e
    end
  end
  local tag_line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local indent = tag_line:match("^%s*") .. "  "
  local anchor = entry and entry.last or row
  vim.api.nvim_buf_set_extmark(buf, ns_hint, anchor - 1, 0, {
    virt_lines = { {
      { indent, "Comment" },
      { "<CR>", "Special" }, { " menu · ", "Comment" },
      { "gx", "Special" }, { " open · ", "Comment" },
      { "[m ]m", "Special" }, { " prev / next", "Comment" },
    } },
  })
  -- Virtual lines under the last buffer line sit below the window edge when
  -- the view was scrolled before they existed; re-anchor the bottom so the
  -- hint is on screen whenever the cursor is at the end of the chat.
  if S.win_showing("chat") and anchor == vim.api.nvim_buf_line_count(buf) then
    vim.api.nvim_win_call(S.wins.chat, function()
      if vim.api.nvim_win_get_cursor(0)[1] == anchor then
        vim.cmd("normal! zb")
      end
    end)
  end
end

function M.message_under_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return (states[buf] and states[buf].line_owner[row]) or nil
end

-- Text for the chat window when nothing is open: a short centred block
-- that reflects what the bridge is doing.
local function splash(width, height)
  local client = require("whatsapp.client")
  -- Each row: { text = ..., hl = line highlight } or { key = ..., text = ... }.
  local rows = { { text = "Whatsapp", hl = "Title" }, {} }
  local function note(text)
    rows[#rows + 1] = { text = text, hl = "Comment" }
  end
  local function key(k, text)
    rows[#rows + 1] = { key = k, text = text }
  end
  if S.fatal then
    note(S.fatal)
    key(":Whatsapp", "tries again")
  elseif S.unlocking then
    note("unlocking the encrypted store…")
    key("GPG", "enter the passphrase in pinentry")
  elseif S.locked then
    local msg = S.unlock_error and ("locked: " .. require("whatsapp.text").single_line(S.unlock_error)) or "store locked"
    note(msg)
    key(":Whatsapp unlock", "decrypt with your GPG key")
    rows[#rows + 1] = {}
    note("session.db stays encrypted on disk while locked")
  elseif not client.running() then
    note(S.fatal or "bridge not running")
    key(":Whatsapp", S.fatal and "tries again" or "restarts it")
  elseif S.qr then
    note("scan with WhatsApp > Linked Devices > Link a Device")
    if height < #S.qr + 4 or width < vim.fn.strdisplaywidth(S.qr[1]) then
      note("code is " .. #S.qr .. " rows · zoom out or enlarge the window to see it all")
    end
    rows[#rows + 1] = {}
    for _, l in ipairs(S.qr) do
      rows[#rows + 1] = { text = l, hl = "Normal" }
    end
    rows[#rows + 1] = {}
    note("waiting for scan · q closes")
  elseif S.pairing then
    note("connecting… waiting for a QR code")
  elseif S.status.paired == false then
    note("not paired")
    rows[#rows + 1] = {}
    key(":Whatsapp pair", "links this device")
    rows[#rows + 1] = {}
    note("then scan the code with WhatsApp > Linked Devices")
  elseif S.replaced then
    note("another client took over this session")
    key(":Whatsapp stop", "then :Whatsapp reconnects")
  elseif not S.status.connected then
    note("connecting…")
  elseif S.sync and not S.synced then
    note("syncing history · " .. (S.sync.chats or 0) .. " chats")
  else
    local unread = 0
    for _, c in ipairs(S.chats) do
      if c.unread > 0 then
        unread = unread + 1
      end
    end
    key("<CR>", "open chat")
    key("u", "next unread")
    key("gU gu ~", "mark unread / read / toggle")
    key("<Tab>", "next pane")
    key("g?", "all keys")
    key("q", "close")
    rows[#rows + 1] = {}
    note("connected · " .. #S.chats .. " chats · " .. unread .. " unread")
    local stale = S.out_of_sync_label()
    if stale then
      rows[#rows + 1] = { text = stale .. " out of sync · open WhatsApp on your phone", hl = "WarningMsg" }
    end
  end

  local keyw = 0
  for _, r in ipairs(rows) do
    if r.key then
      keyw = math.max(keyw, #r.key + 2)
    end
  end
  local block = 0
  for _, r in ipairs(rows) do
    r.line = r.key and (r.key .. string.rep(" ", keyw - #r.key) .. r.text) or (r.text or "")
    block = math.max(block, vim.fn.strdisplaywidth(r.line))
  end
  local pad = string.rep(" ", math.max(0, math.floor((width - block) / 2)))
  local lines, spans = {}, {}
  for _ = 1, math.max(0, math.floor((height - #rows) / 2)) do
    lines[#lines + 1] = ""
  end
  for _, r in ipairs(rows) do
    local line = #lines
    lines[#lines + 1] = r.line ~= "" and (pad .. r.line) or ""
    if r.hl then
      spans[#spans + 1] = { line, 0, -1, r.hl }
    elseif r.key then
      spans[#spans + 1] = { line, #pad, #pad + #r.key, "Special" }
    end
  end
  return lines, spans
end

-- Re-render the current conversation. Keeps the view pinned to the bottom
-- unless the user has scrolled up to read history. opts.bottom forces the
-- jump, for a message the user has just sent.
function M.render(opts)
  local buf = (opts and opts.buf) or S.bufs.chat or M.splash_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local state = st(buf)
  local jid = (opts and opts.jid) or state.jid
  local is_current = jid ~= nil and jid == S.current
  local msgs = (jid and S.messages[jid]) or {}
  local chat = jid and S.chat_by_jid[jid]
  local width = S.text_width("chat", 80)
  local height = S.win_valid("chat") and vim.api.nvim_win_get_height(S.wins.chat) or 20
  -- A picture never takes more than half the pane.
  local image_rows = math.max(1, math.floor(height / 2))
  local lines, owners, spans
  -- A pending QR code takes the pane over even with a chat open: you can
  -- only be pairing because there is no session to read from anyway.
  if S.help and is_current then
    lines, spans = help.layout(width, height)
    owners = {}
  elseif S.view and is_current then
    images.clear(buf)
    lines, spans = images.full_layout(S.view, width, height)
    owners = {}
  elseif not jid or S.qr then
    lines, spans = splash(width, height)
    owners = {}
    -- A wrapped QR code cannot be scanned; let it run off the edge instead.
    if S.win_showing("chat") then
      vim.wo[S.wins.chat].wrap = S.qr == nil
    end
  else
    lines, owners, spans = format.conversation(msgs, chat and chat.is_group)
  end
  if #lines == 0 then
    local text = "no messages yet · S to write"
    lines = { string.rep(" ", math.max(0, math.floor((width - #text) / 2))) .. text }
    spans = { { 0, 0, -1, "Comment" } }
    owners = {}
  end
  state.line_owner = owners
  -- Tag row per media message: the first of its lines that holds the tag.
  state.media_rows = {}
  local seen = {}
  for i, m in pairs(owners) do
    if m.media_type and m.media_type ~= "" then
      if not seen[m] and lines[i]:find("[" .. m.media_type, 1, true) then
        seen[m] = { row = i, m = m, last = i }
        state.media_rows[#state.media_rows + 1] = seen[m]
      end
      if seen[m] and i > seen[m].last then
        seen[m].last = i
      end
    end
  end
  table.sort(state.media_rows, function(a, b) return a.row < b.row end)

  -- The indicator is real buffer text below the last message so following
  -- the bottom keeps it on screen; the timer rewrites just those rows.
  state.typing_start = nil
  local trows = typing_rows(jid)
  if trows then
    state.typing_start = #lines
    for _, r in ipairs(trows) do
      lines[#lines + 1] = r
      spans[#spans + 1] = { #lines - 1, 0, -1, "Comment" }
    end
  end



  -- Follow the bottom unless the user scrolled up in this same chat; a
  -- newly opened chat always starts at its latest message.
  local follow = true
  local old_count = vim.api.nvim_buf_line_count(buf)
  if is_current and S.win_showing("chat") and state.rendered_jid == jid and not (opts and opts.bottom) then
    local row = vim.api.nvim_win_get_cursor(S.wins.chat)[1]
    follow = row >= old_count - 1
  end
  -- Help and the QR code park the cursor at the top; forget the chat so the
  -- next conversation render follows the bottom again.
  if (S.help or S.qr or S.view) and is_current then
    state.rendered_jid = nil
  else
    state.rendered_jid = jid
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  -- Pictures hang under the message at the body's indent, above the hint.
  images.clear(buf)
  for _, e in ipairs(state.media_rows) do
    if e.m.media_type == "image" then
      local indent = "  "
      images.place(buf, e.last, indent, e.m, width - #indent - 1, image_rows)
    end
  end
  for _, s in ipairs(spans) do
    local line, cs, ce, group = s[1], s[2], s[3], s[4]
    if ce == -1 then
      vim.api.nvim_buf_set_extmark(buf, ns, line, 0, { line_hl_group = group })
    else
      vim.api.nvim_buf_set_extmark(buf, ns, line, cs, { end_col = math.min(ce, #lines[line + 1]), hl_group = group })
    end
  end

  if S.win_showing("chat") and S.bufs.chat == buf then
    local name = (S.help and is_current) and "Whatsapp keys"
      or ((S.view and is_current) and ((S.view.filename ~= "" and S.view.filename or "image") .. " · q closes"))
      or (jid and S.chat_title(jid) or "Whatsapp")
    require("whatsapp").set_winbar(S.wins.chat, " " .. S.bar_text(name))
    -- The chat window is often not the current one (the list or compose
    -- pane has focus), and Neovim leaves a non-current window's topline
    -- alone when its buffer changes. Scroll explicitly inside the window so
    -- the view matches the cursor.
    vim.api.nvim_win_call(S.wins.chat, function()
      if ((S.help or S.view) and is_current) or not jid or S.qr then
        -- Help, picture, splash and QR code read from the top.
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.cmd("normal! zt")
      elseif follow then
        vim.api.nvim_win_set_cursor(0, { #lines, 0 })
        vim.cmd("normal! zb")
      end
    end)
  end
  M.update_hint()
  images.commit()
end

-- Update the typing indicator. Appearing or disappearing re-renders the
-- chat; a frame change rewrites the indicator rows in place.
function M.render_typing(advance)
  if advance then
    typing_frame = typing_frame + 1
  end
  local buf = S.bufs.chat
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local state = st(buf)
  local trows = typing_rows(state.jid)
  if trows == nil and state.typing_start == nil then
    return
  end
  if trows == nil or state.typing_start == nil then
    M.render()
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, state.typing_start, -1, false, trows)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, state.typing_start, -1)
  for i = state.typing_start, state.typing_start + #trows - 1 do
    vim.api.nvim_buf_set_extmark(buf, ns, i, 0, { line_hl_group = "Comment" })
  end
end

return M
