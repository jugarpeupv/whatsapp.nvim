# Configuration

All keys are optional. These are the defaults.

```lua
require("whatsapp").setup({
  bin = nil,                                     -- bridge binary, default <plugin>/bin/wa-bridge
  store = vim.fn.stdpath("data") .. "/whatsapp", -- session, messages and media cache
  list_width = 32,
  unread_count = false,                          -- unread message count left of the time
  compose_height = 3,
  page_size = 100,                               -- messages per page, K loads more
  notify = true,                                 -- vim.notify for chats you are not viewing
  mark_read_on_view = true,                      -- send read receipts when you open a chat
  default_reaction = "👍",
  layout = "bubbles",                            -- or "lines", L toggles
  encryption = "none",                           -- "none" or "gpg"
  gpg = {
    key = "",                                    -- fingerprint; falls back to WHATSAPP_GPG_FINGERPRINT
    program = nil,                               -- default: gpg in PATH
    key_file = nil,                              -- default: <store>/session.key.gpg
    home = nil,                                  -- optional GNUPGHOME
  },
  lock_on_resume = true,                         -- lock after a long wall-clock jump (system suspend)
  images = {
    mode = "auto",                               -- "auto", "tag" or "kitty"
    max_width = 60,                              -- cells
    max_height = 20,                             -- rows, at most half the pane
    crop = true,                                 -- crop tall pictures rather than shrink them
  },
})
```

## Encryption

`encryption = "gpg"` wraps a random SQLCipher key with your GPG key. Set `gpg.key` to the fingerprint, or leave it empty and export `WHATSAPP_GPG_FINGERPRINT`; the config value wins. `gpg.program`, `gpg.key_file` and `gpg.home` are only needed for non-default installations. The fingerprint is public; the passphrase is entered through gpg-agent's pinentry (for example `pinentry-mac`) and Neovim never sees it.

The store must be fresh: enabling encryption on an existing plaintext store is refused. Run `:WhatsApp logout`, set the option, then `:WhatsApp pair` again.

`:WhatsApp lock` stops the bridge and drops the key; `:WhatsApp unlock` asks GPG for it again. The bridge also locks when Neovim exits and, with `lock_on_resume`, after a system suspend/wake detected by a wall-clock jump. There is deliberately no auto-lock on focus or idle. While locked there is no WhatsApp connection, so incoming messages wait on the server.

## Images

`kitty` draws pictures inside their bubble and needs a Kitty graphics terminal (Ghostty, kitty, WezTerm, Konsole) plus ImageMagick or macOS `sips`; `tag` shows the `[image ✓]` line and `gx` opens the file. `auto` picks `kitty` when both are found. Inside tmux the plugin enables `allow-passthrough` for its pane.

## Highlight groups

`WhatsAppUnread`, `WhatsAppFilter`, `WhatsAppCurrent`, `WhatsAppTime`, `WhatsAppSender`, `WhatsAppMe`, `WhatsAppMedia`, `WhatsAppSeparator`, `WhatsAppQuote`, `WhatsAppBubble`, `WhatsAppBubbleMe`. Override them after `setup()`.
