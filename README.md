# nvimclaw

**Talk to your OpenClaw agents from inside Vim.**

nvimclaw registers Neovim as an *OpenClaw node* and opens a chat buffer to your active agent session. You write in Vim. You hit `<space>oc`. The buffer is in the chat. Your OpenClaw agent reads it, has opinions, and can edit the buffer directly — using Vim-native operations like `:%s/Artur/Arthur/g` instead of sledgehammer rewrites. The agent's session is the same one you talk to from webchat, so memory, persona, and conversation history carry across surfaces.

This is the Neovim peer of `vscode.openclaw` — ~500 lines of Lua, same node protocol, agent-friendly `nvim.*` command surface, surgical-edit-by-default.

## Screenshot

```
┌──────────────────────────────────┬──────────────────────────────┐
│ ~/writing/Drafts/                │ agent:main:main              │
│  23 schopenhauer.md              │                              │
│                                  │ > you:  change Artur to       │
│ Schopenhauer is hilarious. He    │   Arthur                     │
│ wrote The World as Will...       │                              │
│                                  │ < me:   :%s/Artur/Arthur/g    │
│                                  │   done. 3 replacements.      │
│                                  │   also: "hilarius" on line 1  │
│                                  │   is missing the second "l"  │
│                                  │   in your sources.           │
│                                  │   want me to fix?            │
│                                  │ >                            │
└──────────────────────────────────┴──────────────────────────────┘
       left: live buffer                right: chat buffer
```

## Install

Requires Neovim 0.9+ and an OpenClaw gateway reachable from the machine running Neovim. The default endpoint is `ws://127.0.0.1:18789`, which works when OpenClaw is on the same computer or when an SSH tunnel forwards local port `18789` to another computer.

```lua
-- lua/plugins/nvimclaw.lua  (lazy.nvim)
return {
  "utrumsit/nvimclaw",
  event = "VeryLazy",
  config = function()
    require("nvimclaw").setup({})
  end,
}
```

The gateway token is read from `~/.openclaw/openclaw.json` (the default `openclaw` CLI config) or the `OPENCLAW_GATEWAY_TOKEN` env var. If `~/.openclaw/openclaw.json` has `gateway.mode = "remote"` and `gateway.remote.url = "ws://..."`, nvimclaw uses that URL unless you override `gateway` in `setup()`. Chat works from the gateway token. Tool invocation also requires the gateway to allow the `nvim.*` node commands and approve the `nvimclaw node` pairing once.

## First run

nvimclaw connects to the gateway using the **V3 device-identity** flow. Here's what happens:

1. Plugin loads. On first install, it generates an Ed25519 keypair at `~/.local/state/nvimclaw/identity.json` (mode 0600).
2. Plugin opens an operator WebSocket for chat and a node WebSocket for `nvim.*` tools.
3. Each socket receives a `connect.challenge` nonce, signs the V3 payload (Ed25519), and sends `connect` with the public key.
4. Gateway verifies the signature and returns `hello-ok` with a `deviceToken`.
5. Plugin persists the `deviceToken`. From then on, every Neovim start reuses the keypair and reconnects automatically.
6. If `openclaw nodes status` shows `approval pending`, approve the displayed `nvimclaw node` request. If `nodes invoke` reports `node command not allowed`, add the `nvim.*` commands to `gateway.nodes.allowCommands` and restart the gateway.

If the token rotates, the plugin re-issues and persists a new one transparently. If you delete `~/.local/state/nvimclaw/identity.json`, you wipe the device identity and re-pair on the next launch.

Verify the connection: `:OpenClawStatus` shows separate `chat` and `node` state, `node_id`, gateway, session.

## Sessions

nvimclaw sends chat-buffer messages to one existing OpenClaw session key. The default is `agent:main:main`, which is the default `main` agent's main direct session.

List known sessions:

```bash
openclaw sessions list --agent main
```

Use an existing key in config:

```lua
require("nvimclaw").setup({
  session = "agent:main:main",
})
```

Current OpenClaw releases do not expose a `sessions create` CLI command. To create a new conversation session, start it from an OpenClaw surface such as the dashboard, then use `openclaw sessions list --agent main` to find its key. Do not invent a new key in `init.lua`; `sessions.send` will reject unknown keys with `session not found`.

If the gateway reports `reply session initialization conflicted for agent:main:main`, restart the gateway to clear the wedged reply resolver:

```bash
openclaw gateway restart
```

Then restart Neovim or run `:lua require("nvimclaw.node").stop()` followed by `:lua require("nvimclaw.node").start()`.

## Remote Gateways

nvimclaw can run on one computer while OpenClaw runs on another, as long as the Neovim machine can reach the gateway over plain WebSocket (`ws://`). Common setups:

- **SSH tunnel:** keep nvimclaw pointed at `127.0.0.1:18789`, and run a tunnel such as `ssh -L 18789:127.0.0.1:18789 mac-mini`. This is the easiest secure cross-machine setup.
- **OpenClaw remote config:** on the Neovim machine, use `~/.openclaw/openclaw.json` with `gateway.mode = "remote"`, `gateway.remote.url = "ws://127.0.0.1:18789"` for a tunnel, or another reachable `ws://host:port`.
- **Explicit plugin config:** pass `gateway = { host = "100.x.y.z", port = 18789 }` to `setup()` when the gateway is directly reachable.

The Neovim machine must also have the gateway auth token, either in `OPENCLAW_GATEWAY_TOKEN` or under `gateway.auth.token` in `~/.openclaw/openclaw.json`:

```json
{
  "gateway": {
    "mode": "remote",
    "remote": {
      "url": "ws://127.0.0.1:18789"
    },
    "auth": {
      "token": "..."
    }
  }
}
```

`wss://` / HTTPS gateway URLs are not supported yet; use an SSH tunnel or a directly reachable `ws://` endpoint.

## Tool Permissions

nvimclaw starts in the **`safe`** tier. In safe mode, agents can inspect Neovim state, but they cannot edit buffers, open files, reload files, move your cursor, or run Ex commands. If an agent says it cannot apply a change, this is the first thing to check.

Enable editing tools for the current Neovim session:

```vim
:OpenClawTools privileged
```

Go back to read-only tools:

```vim
:OpenClawTools safe
```

Default to privileged tools from your config:

```lua
require("nvimclaw").setup({
  tools = { tier = "privileged" },
})
```

`privileged` unlocks the mutating tools: `buffer.write`, `buffer.replace_lines`, `buffer.open`, `buffer.reload`, `ex.command`, `ex.substitute`, and `cursor.set`. Path-based tools are still constrained by `workspace_root`.

## Keybindings

Default (set up automatically unless you opt out):

| Key | Action |
|---|---|
| `<space>oc` | Open the chat buffer (auto-attaches current buffer as context) |
| `<space>oC` | Show connection status |
| `<space>os` | Show connection status (`:OpenClawStatus`) |
| `<space>ot` | Toggle tool tier (`:OpenClawTools privileged`) |
| `<space>op` | Pause / resume the gateway connection |

In the chat buffer itself:

| Key | Action |
|---|---|
| `<CR>` | Send the typed message |
| `<C-c>` | Cancel the outbound send before gateway acceptance |
| `gi` | Return to the input prompt after browsing the transcript |

To install without any of the default keybindings, opt out and bind your own:

```lua
require("nvimclaw").setup({
  disable_default_keymaps = true,
})

-- Your own bindings, e.g.:
vim.keymap.set("n", "<leader>oc", function() require("nvimclaw.chat").open() end)
vim.keymap.set("n", "<leader>os", "<Cmd>OpenClawStatus<CR>")
```

The plugin does not own any of these bindings the moment `disable_default_keymaps = true`.

## The `nvim.*` tool surface

The plugin exposes a `nvim.*` command surface for the agent to invoke. There are 14 commands in v0.1, split into two tiers:

- **`safe`** (default): `buffer.current`, `buffer.read`, `search`, `cursor.get`, `selection.get`, `diagnostics.get`, `describe`.
- **`privileged`** (requires opt-in): `buffer.write`, `buffer.replace_lines`, `buffer.open`, `buffer.reload`, `ex.command`, `ex.substitute`, `cursor.set`.

The full tool table — params, return shapes, worked examples for each command, and the conflict-recovery flow — lives in the bundled **`nvimclaw` skill**. Once the skill is published to ClawHub, install it once:

```bash
openclaw skills install @utrumsit/nvimclaw
```

Until then, read it in this repo at [`skills/nvimclaw/SKILL.md`](skills/nvimclaw/SKILL.md). That is the canonical reference agents use. Don't duplicate it here.

## Configuration

```lua
require("nvimclaw").setup({
  -- gateway endpoint. Omit to use defaults or gateway.remote.url from
  -- ~/.openclaw/openclaw.json when gateway.mode = "remote".
  gateway = nil,

  -- existing OpenClaw session key to send messages to
  -- default: "agent:main:main"
  session = "agent:main:main",

  -- keybind to summon the chat (default "<space>oc")
  keymap = "<space>oc",

  -- auto-attach context when chat opens:
  -- "buffer" | "selection" | "none"
  attach = "buffer",

  -- path boundary for tool access; relative tool paths resolve inside this root
  workspace_root = vim.fn.getcwd(),

  -- receive timeout for chat request/response delivery (ms)
  receive_timeout_ms = 15000,

  -- tool tier at startup: "safe" (default) | "privileged"
  tools = { tier = "safe" },

  -- set true to install no default keybindings
  disable_default_keymaps = false,

  -- chat UI options
  chat = {
    side  = "right",  -- "right" | "left" | "bottom"
    width = 0.4,      -- fraction of screen for vertical splits
  },

  -- structured-logging redacted by default; flip on for diagnosis
  debug_content = false,
})
```

Path access is guarded: any buffer path outside `workspace_root` returns a `path_denied` error. Tier `privileged` must be set in config or enabled at runtime via `:OpenClawTools privileged` before mutating commands succeed.

When an agent needs "the file I'm looking at", it should call `nvim.buffer.current` first instead of guessing from cwd or disk. If the cursor is in the `nvimclaw://chat` split, nvimclaw targets the last focused or edited normal buffer instead of the chat buffer. Named buffers can be targeted by `path`; unnamed buffers can be targeted by the returned `buffer_id`. If an external fallback writes to disk, `nvim.buffer.reload` can run `:checktime` or `:edit!`; the plugin also runs `checktime` on focus/buffer/cursor idle for unmodified buffers.

## How it works

nvimclaw is built on two related-but-distinct capabilities that use separate WebSocket connections to the OpenClaw gateway:

- **Surface** — Neovim *subscribes to* a session. `<space>oc` opens a chat buffer; messages you type there become normal user turns on the agent session. The session you talk to from webchat is the same one — memory and persona carry across. Identity is `surface_id = "nvim:<hostname>:<boot_uuid>"`, scoped to one process.
- **Node** — Neovim *responds to* invocations from the agent. The agent calls `openclaw nodes invoke --node <id> --command nvim.ex.substitute` and the plugin runs `:s/pat/repl/flags` against the buffer. Identity is the node-id assigned at pair time.

The split matters: a *surface* posting user messages would blur trust boundaries, so user-turns only flow through the chat buffer, never through the public `nvim.*` command surface. In current OpenClaw, the plugin therefore keeps an operator socket for chat and a node socket for tool invocation.

Transport: WebSocket. Auth: V3 device-identity (Ed25519 keypair signed challenge + `deviceToken` from `hello-ok`). Optimistic locking: every mutating tool accepts `expected_changedtick` and (optionally) `expected_line_hash` for stale-edit protection.

## Limitations (v0.1)

- **No token streaming.** Request/response chat only. Final `chat` events render the complete assistant turn in one go. Real-time token streaming lands in v1.1; the internals are already event-based to make the swap a UI change.
- **Single device identity per Neovim process.** Each `~/.local/state/nvimclaw/identity.json` corresponds to one node. Multiple concurrent Neovim processes on one host work (different `boot_uuid` per process), but there is no concept of multiple identities per process.
- **Single session at a time.** You pick one session to send to from the chat buffer; switching requires a `:OpenClawSwitchSession` (planned for v1.1, not in v0.1).
- **Limited test surface.** v0.1 ships a headless-Neovim smoke suite for the core tool behavior. A fake-node gateway smoke can land later.
- **No plugin→skill version handshake.** Compatibility is one-way: the skill declares `requires nvimclaw: ">=0.1.4"`, and `nvim.describe` returns `protocol_version` so agents can introspect what's actually available. There is no runtime "load skill X with plugin Y" call.

## Testing

Run the local regression suite:

```bash
./scripts/test.sh
```

It checks Lua syntax and runs a headless Neovim integration test covering tool registration, safe-vs-privileged gating, chat-focused buffer targeting, unnamed buffer targeting by `buffer_id`, guarded line replacement, paragraph append, `:substitute` dry-run/apply, Ex-command layout preservation, and workspace path denial.

## Contributing

This plugin is in active development. Keep changes narrow, readable, and covered by the headless regression suite where behavior changes.

Style:
- Lua files: `lua/nvimclaw/` modules, headers in plain English, function names spelled out.
- Tests: run `./scripts/test.sh`.
- Commit messages: short imperative subject, with the body explaining user-visible behavior or compatibility impact when relevant.

## License

[MIT](LICENSE) — Copyright (c) 2026 utrumsit.

## Credits

Written by [utrumsit](https://github.com/utrumsit). The design is informed by, and borrows the surface/node shape from, two prior works:

- [`vscode.openclaw`](https://github.com/xiaoyaner-home/openclaw-vscode/) — Xiaoyan's VSCode extension, the reference editor-as-node implementation. nvimclaw mirrors its auth model and command-surface shape.
- The [OpenClaw source](https://github.com/openclaw/openclaw) — the gateway, the V3 device-identity protocol, the node protocol. nvimclaw speaks the wire format defined there.
