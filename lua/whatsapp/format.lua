-- Pure functions that turn bridge rows into buffer lines plus highlight
-- spans. Kept free of editor calls so they are easy to test.
local M = {}
local text = require("whatsapp.text")

local function pad_right(s, width)
  local len = vim.fn.strdisplaywidth(s)
  if len >= width then
    return text.fit(s, width)
  end
  return s .. string.rep(" ", width - len)
end

local function day_of(ts)
  return os.date("%Y-%m-%d", ts)
end

function M.short_time(ts)
  if ts == 0 then
    return ""
  end
  if day_of(ts) == day_of(os.time()) then
    return os.date("%H:%M", ts)
  end
  return os.date("%d %b", ts)
end

-- Chat list: "● Name              12:40", or "● Name           3 12:40" with
-- show_counts. Returns lines, jids per line, and which lines are unread.
function M.chat_list(chats, width, show_counts)
  local lines, jids, unread = {}, {}, {}
  for i, c in ipairs(chats) do
    local mark = c.unread > 0 and "●" or " "
    local right = M.short_time(c.last_ts)
    if show_counts and c.unread > 0 then
      right = c.unread .. " " .. right
    end
    local name_width = math.max(4, width - 2 - #right - 1)
    lines[i] = mark .. " " .. pad_right(text.name(c.name ~= "" and c.name or c.jid), name_width) .. " " .. right
    jids[i] = c.jid
    unread[i] = c.unread > 0
  end
  return lines, jids, unread
end

local function duration(seconds)
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Voice note levels (0-100) as a row of block characters. Buckets take the
-- loudest sample so the shape stays spiky, and levels are scaled to the
-- loudest point in the clip so quiet notes still show a shape.
function M.waveform(levels, cols)
  local blocks = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
  if not levels or #levels == 0 then
    return ""
  end
  cols = math.min(cols, #levels)
  local peak = 1
  for _, v in ipairs(levels) do
    peak = math.max(peak, v)
  end
  local out = {}
  for i = 1, cols do
    local lo = math.floor((i - 1) * #levels / cols) + 1
    local hi = math.floor(i * #levels / cols)
    local v = 0
    for j = lo, math.max(lo, hi) do
      v = math.max(v, levels[j] or 0)
    end
    out[i] = blocks[math.max(1, math.ceil(v / peak * #blocks))]
  end
  return table.concat(out)
end

local function media_tag(m)
  if m.media_type == nil or m.media_type == "" then
    return nil
  end
  local parts = { m.media_type }
  -- Generic names say nothing: voice notes are always audio.ogg and phone
  -- photos arrive as image.jpg. A real filename is worth the space.
  local generic = m.media_type == "voice" or (m.filename or ""):match("^image%.%w+$") ~= nil
  if not generic and m.filename and m.filename ~= "" then
    parts[#parts + 1] = text.name(m.filename)
  end
  if m.seconds and m.seconds > 0 then
    parts[#parts + 1] = duration(m.seconds)
  end
  if m.media_type == "voice" then
    local wave = M.waveform(m.waveform, 12)
    if wave ~= "" then
      parts[#parts + 1] = wave
    end
  end
  parts[#parts + 1] = m.cached and "✓" or "⇣"
  return "[" .. table.concat(parts, " ") .. "]"
end

-- Typing indicator: "Alice is typing.." below the last message.
function M.typing_line(who, frame, media)
  local verb = media == "audio" and "is recording audio" or "is typing"
  return text.name(who) .. " " .. verb .. string.rep(".", ((frame - 1) % 3) + 1)
end

-- Conversation: one header per message with the sender, time and, for our
-- own messages, a read tick. The body is indented two spaces.
-- Returns lines, a message per line (nil for separators), and highlight
-- spans {line, col_start, col_end, group}.
function M.conversation(messages, is_group)
  local lines, owners, spans = {}, {}, {}
  local last_day = nil
  local function add(line, owner)
    lines[#lines + 1] = line
    owners[#lines] = owner
    return #lines
  end
  for _, m in ipairs(messages) do
    local day = day_of(m.ts)
    if day ~= last_day then
      if #lines > 0 then
        add("", nil)
      end
      local label = os.date("%a %d %b %Y", m.ts)
      local n = add("── " .. label .. " ──", nil)
      spans[#spans + 1] = { n - 1, 0, -1, "WhatsAppSeparator" }
      last_day = day
    else
      add("", nil)
    end

    local time = os.date("%H:%M", m.ts)
    local who = m.from_me and "me" or (m.sender_name ~= "" and m.sender_name or m.sender)
    if not is_group and not m.from_me then
      who = m.sender_name ~= "" and m.sender_name or who
    end
    who = text.name(who)
    local tick = m.from_me and (m.read and "✓✓" or "✓") or ""
    local header = who .. " (" .. time .. ")" .. (tick ~= "" and (" " .. tick) or "")
    local n = add(header, m)
    local name_group = m.from_me and "WhatsAppMe" or "WhatsAppSender"
    spans[#spans + 1] = { n - 1, 0, #who, name_group }
    local time_start = #who + 2
    spans[#spans + 1] = { n - 1, time_start, time_start + #time, "WhatsAppTime" }
    if tick ~= "" then
      local tick_start = time_start + #time + 2
      spans[#spans + 1] = { n - 1, tick_start, tick_start + #tick, "WhatsAppRead" }
    end

    if m.quoted_text and m.quoted_text ~= "" then
      local q = m.quoted_text:gsub("\n", " ")
      local qn = add("  ↳ " .. q, m)
      spans[#spans + 1] = { qn - 1, 0, -1, "WhatsAppQuote" }
    end

    local body = m.text or ""
    local tag = media_tag(m)
    if tag then
      body = body ~= "" and (tag .. " " .. body) or tag
    end
    local first_body = true
    for part in (body .. "\n"):gmatch("(.-)\n") do
      local bn = add(part == "" and "" or ("  " .. part), m)
      if first_body and tag then
        spans[#spans + 1] = { bn - 1, 2, 2 + #tag, "WhatsAppMedia" }
      end
      first_body = false
    end
  end
  return lines, owners, spans
end

return M
