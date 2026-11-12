# whatsapp.nvim

WhatsApp inside Neovim. A chat list, a conversation buffer, and a compose
buffer that only appears when you ask for it.

Built on [whatsmeow](https://github.com/tulir/whatsmeow), which implements the
WhatsApp Web multi-device protocol. The plugin appears on your phone as a
linked device. This is an unofficial client and may violate WhatsApp's terms
of service. Use it at your own risk.

## How it works

```
Neovim ──stdio (JSON lines)──▶ bin/wa-bridge (Go, whatsmeow) ──▶ WhatsApp
  lua/whatsapp/*                 SQLite stores under the store directory
```

The bridge runs as a child process of Neovim, like a language server.
Incoming messages are pushed to the editor as events, so the open chat updates
live and other chats raise a notification.

## Install

Requires Go 1.26.9+ and a C compiler (SQLite is cgo).

vim-plug:

```vim
Plug 'dwmkerr/whatsapp.nvim', { 'do': 'make build' }
```

lazy.nvim:

```lua
{
  "dwmkerr/whatsapp.nvim",
  build = "make build",
  config = function()
    require("whatsapp").setup()
  end,
}
```

For a local checkout, point `dir` at the repository root:

```lua
{
  dir = vim.fn.expand("~/projects/whatsapp.nvim"),
  build = "make build",
  config = function()
    require("whatsapp").setup()
  end,
}
```

Then pair once:

```vim
:Whatsapp pair
```

Scan the QR code from your phone: WhatsApp > Settings > Linked Devices >
Link a Device. History syncs in the background.

If the splash says read marks are out of sync, open WhatsApp on your phone.
On some accounts WhatsApp's server copy of read marks, pins and mutes cannot
be verified, and only the phone can send a good copy. Pairing again does not
help.

## Use

`:Whatsapp` opens the chat list in the current window. It does not create a
tab and does not open a conversation until you select one.

| Command | What |
|---|---|
| `:Whatsapp` | Chat list in the current window |
| `:Whatsapp open vertical` | Chat list in a right-hand vertical split |
| `:Whatsapp open horizontal` | Chat list in a split below the current window |
| `:Whatsapp open tab` | Chat list and conversation in a new tab |
| `:Whatsapp Alice` | Open the chat matching "Alice" |
| `:Whatsapp pair` | Show the pairing QR code |
| `:Whatsapp unlock` | Decrypt the store with your GPG key |
| `:Whatsapp lock` | Stop the bridge and drop the key |
| `:Whatsapp logout` | Unlink this device and wipe the local store |
| `:Whatsapp status` | Bridge status |
| `:Whatsapp stop` | Close and stop the bridge |
| `:Whatsapp names` | Refresh contact names; runs on connect too |

The list and every conversation are normal `buflisted` buffers, so they show in
`:ls` and can be reached from any window:

```vim
:buffer whatsapp://chats
:buffer whatsapp://paqui-garcia
:buffer whatsapp://group-climbing
```

The list is always `whatsapp://chats`. A contact becomes its slugified name, a
group `group-<slug>`, with a short hash appended only when two names collide.
Spaces and punctuation are removed, so the name is safe to type in `:buffer`.
Opening one of these buffers directly does not require going through the
Whatsapp pane first.

Chat list:

| Key | What |
|---|---|
| `<CR>` `l` | Open the chat under the cursor |
| `u` | Open the next unread chat |
| `f` | Cycle the filter: all / unread / groups |
| `gU` `gu` `~` | Mark unread / read / toggle, mirrored to your phone |
| `gx` `]m` `[m` | Open / next / previous media in the open chat |
| `K` | Load older messages in the open chat |
| `<Tab>` `<S-Tab>` | Cycle panes |
| `g?` | All keys |
| `q` | Close Whatsapp |

Conversation:

| Key | What |
|---|---|
| `S` | Open the compose buffer below |
| `R` | Reply to the message under the cursor |
| `r` | React to the message under the cursor |
| `<CR>` | Media menu: download, open, copy path |
| `gx` | Download if needed, then confirm before opening |
| `]m` `[m` | Next / previous media |
| `K` | Load older messages |
| `gU` `gu` `~` | Mark chat unread (back to the list) / read / toggle |
| `<Tab>` `<S-Tab>` | Cycle panes |
| `g?` | All keys |
| `/` `n` `gg` `G` | Native search and movement |
| `q` | Back to the chat list |

Compose (only after `S`):

| Key | What |
|---|---|
| `:w` | Send and close the compose buffer |
| `q` | Close compose |
| `<CR>` `gx` | Media menu / open media, in normal mode |
| `]m` `[m` | Next / previous media |
| `<Tab>` `<S-Tab>` | Cycle panes |
| `g?` | All keys |

Each chat keeps its own draft and reply target in memory until Neovim exits.
A send response only clears the original draft if it has not been edited while
sending.

Messages render as a sender header, time and read tick, followed by the body:

```
Paqui García (15:38)
  hello worlds

me (15:39) ✓✓
  see you
```

`✓` is an own message; `✓✓` means the other side read it. Incoming messages
have no tick.

Media shows as a tag in the body: `[image photo.jpg]`,
`[video clip.mp4 0:12]`, and voice notes as duration plus waveform.
`⇣` means not downloaded yet, `✓` means the file is in the cache.
`<CR>` and `gx` act on the media under the cursor, or on the newest media in
the chat when the cursor is elsewhere; the target carries a hint under it,
and `]m` `[m` move between attachments.

Attachments download without opening an application. Use `gx` to open one,
with confirmation for every file type. Downloads stream to a temporary file
and are checked before entering the cache. Each attachment is limited to
25 MiB and 60 seconds, with at most two downloads at once.

## Configure

```lua
require("whatsapp").setup({
  store = vim.fn.stdpath("data") .. "/whatsapp",
  list_width = 32,          -- vertical split and tab list width
  list_height = 15,         -- horizontal split height
  unread_count = false,     -- show unread counts in the chat list
  compose_height = 3,
  page_size = 100,
  notify = true,
  mark_read_on_view = true,
  default_reaction = "👍",
  images = { mode = "auto" },
  encryption = "none",      -- "none" or "gpg"
  gpg = {
    key = "",               -- falls back to WHATSAPP_GPG_FINGERPRINT
    home = nil,             -- falls back to WHATSAPP_GPG_HOME
  },
  lock_on_resume = true,
})
```

See [Configuration](docs/configuration.md) for every option, image modes and
highlight groups.

## Encrypted store

`encryption = "gpg"` keeps `session.db` and `messages.db` encrypted with
SQLCipher. A random 32-byte key protects them; that key is stored as
`session.key.gpg`, encrypted to your GPG key. GPG is only asked for the small
key, never for the whole database, and the passphrase is handled by
gpg-agent/pinentry (for example `pinentry-mac`), not by Neovim.

```lua
require("whatsapp").setup({
  encryption = "gpg",
  gpg = { key = "YOUR_GPG_FINGERPRINT" },
})
```

The fingerprint can come from the environment instead of the config:

```sh
export WHATSAPP_GPG_FINGERPRINT=YOUR_GPG_FINGERPRINT
export WHATSAPP_GPG_HOME="$HOME/.local/share/whatsapp-gnupg"
```

`gpg.key` and `gpg.home` win when both are set. The fingerprint is public; the
passphrase still goes only to gpg-agent/pinentry.

### Recommended: a dedicated GPG key and agent

Using your everyday GPG key works, but its gpg-agent cache is shared with git,
mail and everything else, and it may keep the passphrase warm. A dedicated key
in its own `GNUPGHOME` lets Whatsapp ask every time without making every commit
prompt.

Run this once:

```sh
WAGH="$HOME/.local/share/whatsapp-gnupg"
mkdir -p -m 700 "$WAGH"

cat > "$WAGH/gpg-agent.conf" <<'EOF'
default-cache-ttl 0
max-cache-ttl 0
no-allow-external-cache
pinentry-program /opt/homebrew/bin/pinentry-mac
EOF
chmod 600 "$WAGH/gpg-agent.conf"

GNUPGHOME="$WAGH" gpg --quick-gen-key \
  "Whatsapp nvim <whatsapp@localhost>" default default never

FPR=$(GNUPGHOME="$WAGH" gpg --with-colons --list-keys |
  awk -F: '/^fpr/ { print $10; exit }')

export WHATSAPP_GPG_HOME="$WAGH"
export WHATSAPP_GPG_FINGERPRINT="$FPR"
```

Adjust `pinentry-program` if you do not use the Homebrew pinentry-mac. Then
configure the plugin without hardcoding either value:

```lua
require("whatsapp").setup({
  encryption = "gpg",
  gpg = {}, -- WHATSAPP_GPG_HOME and WHATSAPP_GPG_FINGERPRINT
})
```

Export the two variables from your shell profile, or put them in `gpg.home`
and `gpg.key` if Neovim is launched from a GUI that does not inherit your
shell. Restart Neovim after changing them; a running editor does not pick up a
new environment.

Test the agent before using it:

```sh
printf test |
  GNUPGHOME="$WAGH" gpg --encrypt --recipient "$FPR" |
  GNUPGHOME="$WAGH" gpg --decrypt
```

If the store already exists, `session.key.gpg` is encrypted to the old key:
log out and pair again, or rewrap that file to the new fingerprint. Back up the
dedicated secret key somewhere safe; losing it means re-pairing, and losing it
with the old key also means losing the local history.

Enabling encryption on an existing plaintext store is deliberately not
automatic. Run `:Whatsapp logout`, enable the option, and pair again. The first
run creates the wrapped key; later runs decrypt it at startup. If the GPG
prompt is cancelled, the bridge stays locked and `:Whatsapp unlock` retries
without restarting the editor.

The session is locked by `:Whatsapp lock`, when Neovim exits, and after a
system suspend/wake detected by a wall-clock jump (`lock_on_resume`). There is
no lock on focus changes or idle time. Locking stops the bridge, so messages
are queued by WhatsApp until you unlock.

The lock is only as strong as GPG's prompt. If gpg-agent has the passphrase
cached, or pinentry-mac has saved it in the macOS Keychain, `gpg --decrypt`
can return the key without asking. Disable "Save in Keychain" in pinentry-mac
and set `default-cache-ttl 0` (and `max-cache-ttl 0`) in `gpg-agent.conf` if
you want every unlock to require the passphrase or a smartcard touch.

`logout` closes the container and deletes `session.db*`, `messages.db*`,
`session.key.gpg` and `media/`. Downloaded media is a cache, not part of
SQLCipher, so it stays plaintext while it exists.

## Develop

```sh
make build     # compile the bridge into bin/wa-bridge
make test      # Go tests plus the headless Neovim test
```

Run the bridge by hand to poke the protocol:

```sh
printf '{"id":1,"method":"status"}\n' | ./bin/wa-bridge -store /tmp/wa
```

### Bridge protocol

One JSON object per line. Requests carry an `id` and `method`; responses echo
the `id` with `result` or `error`; events have no `id`.

Methods: `status`, `unlock`, `pair.start`, `logout`, `chats.list`,
`messages.list {jid, limit, before}`, `message.send {jid, text, reply_to}`,
`message.react {jid, id, emoji}`, `chat.read {jid}`, `chat.unread {jid}`,
`presence {available}`, `media.download {jid, id}`,
`contacts.search {query}`.

Events: `ready`, `unlocked`, `unpaired`, `connected`, `disconnected`,
`logged_out`, `pair.qr {lines}`, `pair.ok`, `pair.timeout`, `pair.error`,
`typing {chat, sender, sender_name, state, media}`,
`message {chat_name, message}`, `messages.read {chat, ids}`, `chats.changed`,
`sync.progress`, `sync.done`, `appstate.waiting {name}`,
`appstate.synced {name}`, `fatal`.

## Privacy

Everything stays on your machine in the store directory: the session keys,
the message database, and downloaded media. Encrypt the store if the directory
might be copied, backed up or synced. Keep it out of cloud-synced folders
regardless.

The store is created owner-only (`0700`, databases `0600`). Display names have
control characters removed and line breaks replaced with spaces; winbar text
is also escaped. Media paths are sanitised, and image, video and audio
extensions come from a small list of recognised MIME types for that media
family. Unknown types become `.bin`. A recognised extension does not establish
that a file is safe: opening any attachment requires confirmation.

## License

MIT. See [LICENSE](LICENSE).
