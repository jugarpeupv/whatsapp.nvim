# Configuration

All keys are optional. These are the defaults.

```lua
require("whatsapp").setup({
  bin = nil,                                     -- bridge binary, default <plugin>/bin/wa-bridge
  store = vim.fn.stdpath("data") .. "/whatsapp", -- session, messages and media cache
  list_width = 32,                               -- vertical split and tab list width
  list_height = 15,                              -- horizontal split height
  unread_count = false,                          -- unread message count left of the time
  compose_height = 3,
  page_size = 100,                               -- messages per page, K loads more
  notify = true,                                 -- vim.notify for chats you are not viewing
  mark_read_on_view = true,                      -- send read receipts when you open a chat
  default_reaction = "👍",
  encryption = "none",                           -- "none" or "gpg"
  gpg = {
    key = "",                                    -- fingerprint; falls back to WHATSAPP_GPG_FINGERPRINT
    program = nil,                               -- default: gpg in PATH
    key_file = nil,                              -- default: <store>/session.key.gpg
    home = nil,                                  -- GNUPGHOME; falls back to WHATSAPP_GPG_HOME
  },
  lock_on_resume = true,                         -- lock after a long wall-clock jump (system suspend)
  lock_on_focus_lost = false,                    -- lock shortly after the terminal/app loses focus
  images = {
    mode = "auto",                               -- "auto", "tag" or "kitty"
    max_width = 60,                              -- cells
    max_height = 20,                             -- rows, at most half the pane
    crop = true,                                 -- crop tall pictures rather than shrink them
  },
})
```

## Encryption

`encryption = "gpg"` wraps a random SQLCipher key with your GPG key. Set `gpg.key` to the fingerprint, or leave it empty and export `WHATSAPP_GPG_FINGERPRINT`; the config value wins. `gpg.home` selects a dedicated `GNUPGHOME`, or falls back to `WHATSAPP_GPG_HOME`. `gpg.program` and `gpg.key_file` are only needed for non-default installations. The fingerprint is public; the passphrase is entered through gpg-agent's pinentry (for example `pinentry-mac`) and Neovim never sees it.

A dedicated key in its own `GNUPGHOME` is recommended so its agent can have `default-cache-ttl 0` without affecting git or mail; see the main README for the commands.

The store must be fresh: enabling encryption on an existing plaintext store is refused. Run `:Whatsapp logout`, set the option, then `:Whatsapp pair` again.

`:Whatsapp lock` stops the bridge and drops the key; `:Whatsapp unlock` asks GPG for it again. The bridge also locks when Neovim exits, with `lock_on_resume` after a system suspend/wake detected by a wall-clock jump, and with `lock_on_focus_lost` about 250 ms after the terminal/app loses focus. Locking calls the same path as `:Whatsapp lock`, so the conversation buffers are cleared and a locked splash is shown. There is no idle-time lock. While locked there is no WhatsApp connection, so incoming messages wait on the server. Focus events depend on the terminal: tmux needs `focus-events on`, and Terminal.app does not report them reliably.

## Opening

`:Whatsapp` puts the chat list in the current window. `:Whatsapp open vertical` uses a right-hand vertical split, `:Whatsapp open horizontal` a split below, and `:Whatsapp open tab` a new tab with the list and conversation side by side. No conversation is opened until you press `<CR>` on a chat. `S` in a conversation opens the compose buffer below it; `:w` sends and closes it.

The list is the listed buffer `whatsapp://chats`. Every conversation is also a listed buffer: a contact becomes `<slugified-name>`, a group `group-<slugified-name>`. Use `:buffer whatsapp://paqui-garcia` to open one directly; the plugin updates the active conversation when the buffer is entered. A short hash is appended only if two names would collide.

## Messages

Messages are rendered as a sender header with the time and, for your own messages, a read tick:

```
Paqui García (15:38)
  hello worlds

me (15:39) ✓✓
  see you
```

`WhatsAppSender` and `WhatsAppMe` are bold; `WhatsAppRead` highlights the tick.

## Images

`kitty` draws pictures in the conversation and needs a Kitty graphics terminal (Ghostty, kitty, WezTerm, Konsole) plus ImageMagick or macOS `sips`; `tag` shows the `[image ✓]` line and `gx` opens the file. `auto` picks `kitty` when both are found. Inside tmux the plugin enables `allow-passthrough` for its pane.

## Highlight groups

`WhatsAppUnread`, `WhatsAppFilter`, `WhatsAppCurrent`, `WhatsAppTime`, `WhatsAppSender`, `WhatsAppMe`, `WhatsAppRead`, `WhatsAppMedia`, `WhatsAppSeparator`, `WhatsAppQuote`. Override them after `setup()`.
