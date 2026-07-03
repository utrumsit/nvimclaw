--[[
  plugin/nvimclaw.lua — user commands, autocmds, and bootstrap.

  This file is sourced automatically by Neovim when the plugin/ directory
  is on the runtimepath (which happens immediately for plugins installed
  manually or via lazy.nvim after the first load).

  It does three things:
    1. Defines :OpenClaw* user commands.
    2. Defines a VimLeavePre autocmd to cleanly close the WS connection
       so we don't leak zombie sockets on shutdown.
    3. Guards against double-loading.

  NOTE: Default keymaps (<space>oc, <space>oC) are NOT registered here.
  They're registered by require("nvimclaw").setup() (init.lua) so they can
  honor the `disable_default_keymaps` config flag. This file only handles
  commands and autocmds that have no config dependency at load time.

  Commands defined:
    :OpenClawSetup            — run require("nvimclaw").setup({...})
    :OpenClawConnect          — manually trigger Node.start()
    :OpenClawDisconnect       — Node.stop()
    :OpenClawInput            — jump to the chat input line
    :OpenClawStatus           — show connection state + node info
    :OpenClawTools <tier>     — toggle tool tier (safe | privileged)
    :OpenClawPair             — legacy alias for :OpenClawSetup
]]

-- Idempotency guard: this file may be sourced multiple times (e.g. on
-- :source, or if lazy.nvim reloads it). Bail early on the second pass.
if vim.g.loaded_nvimclaw == 1 then
  return
end
vim.g.loaded_nvimclaw = 1

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Run a function, swallowing any error so user commands never crash Neovim.
-- Errors are echoed to :messages so the user sees what went wrong.
local function safe(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      vim.api.nvim_echo({ { "[nvimclaw] " .. tostring(err), "ErrorMsg" } }, true, { err = true })
    end
  end
end

--- Lazy require of a nvimclaw submodule. Done inside each command so
-- nothing fails at load time if a submodule has an unrelated bug.
local function lazy(name)
  return function(...)
    local mod = require(name)
    if type(mod) == "function" then
      return mod(...)
    else
      -- default entry point for nvimclaw modules is .setup
      return (mod.setup or mod)(...)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

--- :OpenClawSetup [opts-as-string]
-- opts-as-string is a Lua table literal, e.g. `{ gateway = { port = 19000 } }`.
-- If omitted, setup() is called with no args (defaults).
vim.api.nvim_create_user_command("OpenClawSetup", function(cmd)
  local opts = nil
  if cmd.args and cmd.args ~= "" then
    local chunk, err = loadstring("return " .. cmd.args)
    if not chunk then
      vim.api.nvim_echo({ { "[nvimclaw] invalid opts: " .. tostring(err), "ErrorMsg" } }, true, { err = true })
      return
    end
    local ok, result = pcall(chunk)
    if not ok or type(result) ~= "table" then
      vim.api.nvim_echo({ { "[nvimclaw] opts must be a Lua table", "ErrorMsg" } }, true, { err = true })
      return
    end
    opts = result
  end
  safe(lazy("nvimclaw"))(opts)
end, {
  nargs    = "*",
  desc     = "nvimclaw: initialize the plugin (default args)",
  complete = "file",
})

--- :OpenClawConnect — bring up the gateway WebSocket.
vim.api.nvim_create_user_command("OpenClawConnect", safe(function()
  local Node = require("nvimclaw.node")
  Node.start()
  if Node.start_node then Node.start_node() end
end), { desc = "nvimclaw: connect to gateway" })

--- :OpenClawDisconnect — close the gateway WebSocket.
vim.api.nvim_create_user_command("OpenClawDisconnect", safe(function()
  local Node = require("nvimclaw.node")
  Node.stop()
end), { desc = "nvimclaw: disconnect from gateway" })

--- :OpenClawInput — focus the chat input prompt.
vim.api.nvim_create_user_command("OpenClawInput", safe(function()
  local Chat = require("nvimclaw.chat")
  Chat.jump_to_input()
end), { desc = "nvimclaw: jump to chat input" })

--- :OpenClawStatus — show connection state, node id, device id, session.
vim.api.nvim_create_user_command("OpenClawStatus", safe(function()
  local status = require("nvimclaw").status()
  local lines = {
    "nvimclaw status",
    "─────────────",
    "  chat:      " .. tostring(status.state),
    "  node:      " .. tostring(status.node_state),
    "  node_id:   " .. tostring(status.node_id or "(not yet assigned)"),
    "  device_id: " .. tostring(status.device_id or "(not yet assigned)"),
    "  token:     " .. tostring(status.device_token or "no"),
    "  session:   " .. tostring(status.session),
  }
  vim.api.nvim_echo({ { table.concat(lines, "\n"), "None" } }, false, {})
end), { desc = "nvimclaw: show connection status" })

--- :OpenClawReconnect — stop then start the gateway WebSocket.
vim.api.nvim_create_user_command("OpenClawReconnect", safe(function()
  local Node = require("nvimclaw.node")
  Node.stop()
  vim.defer_fn(function()
    Node.start()
    if Node.start_node then Node.start_node() end
  end, 100)
end), { desc = "nvimclaw: reconnect to gateway" })

--- :OpenClawTools <safe|privileged>
-- Toggles the tool tier at runtime. We re-apply config so the change
-- takes effect for subsequent tool invocations.
vim.api.nvim_create_user_command("OpenClawTools", safe(function(cmd)
  local tier = cmd.args
  if tier ~= "safe" and tier ~= "privileged" then
    vim.api.nvim_echo({
      { "[nvimclaw] tier must be 'safe' or 'privileged' (got: " .. tostring(tier) .. ")", "ErrorMsg" },
    }, true, { err = true })
    return
  end

  local Config = require("nvimclaw.config")
  local current = Config.current()
  -- Merge the new tier onto the existing config; this preserves all
  -- other user opts (gateway, session, etc.).
  Config.apply({
    -- Preserve everything we know about, then override the tier.
    gateway                = current.gateway,
    session                = current.session,
    keymap                 = current.keymap,
    attach                 = current.attach,
    chat                   = current.chat,
    identity_path          = current.identity_path,
    log_path               = current.log_path,
    receive_timeout_ms     = current.receive_timeout_ms,
    workspace_root         = current.workspace_root,
    disable_default_keymaps = current.disable_default_keymaps,
    log_level              = current.log_level,
    debug_content          = current.debug_content,
    tools                  = { tier = tier },
  })

  vim.api.nvim_echo({ { "[nvimclaw] tool tier set to: " .. tier, "None" } }, false, {})
end), {
  nargs    = 1,
  desc     = "nvimclaw: set tool tier (safe | privileged)",
  complete = function() return { "safe", "privileged" } end,
})

--- :OpenClawPair — legacy alias for :OpenClawSetup.
-- Device-identity auto-pair subsumes the old explicit node.pair.approve flow.
-- We keep this command for muscle memory.
vim.api.nvim_create_user_command("OpenClawPair", safe(function(cmd)
  vim.api.nvim_echo({
    { "[nvimclaw] :OpenClawPair is now an alias for :OpenClawSetup.", "None" },
    { "             Device identity auto-pair handles auth on first connect.", "None" },
  }, false, {})
  -- Delegate to :OpenClawSetup.
  local opts = nil
  if cmd.args and cmd.args ~= "" then
    local chunk, err = loadstring("return " .. cmd.args)
    if chunk then
      local ok, result = pcall(chunk)
      if ok and type(result) == "table" then opts = result end
    end
  end
  require("nvimclaw").setup(opts)
end), {
  nargs    = "*",
  desc     = "nvimclaw: pair (alias for :OpenClawSetup)",
  complete = "file",
})

-- ---------------------------------------------------------------------------
-- Autocmds
-- ---------------------------------------------------------------------------

--- Gracefully close the WebSocket on shutdown.
-- Without this, Neovim can exit while the WS loop is mid-write and the
-- gateway logs a "connection reset" instead of a clean close.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group    = vim.api.nvim_create_augroup("nvimclaw_lifecycle", { clear = true }),
  pattern  = "*",
  callback = safe(function()
    local Node = require("nvimclaw.node")
    if Node.stop then Node.stop() end
  end),
})

--- When the plugin is unloaded (lazy.nvim :Lazy reload), tear down state.
-- Currently a no-op beyond VimLeavePre; reserved for future hot-reload
-- cleanup.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group    = vim.api.nvim_create_augroup("nvimclaw_unload", { clear = true }),
  pattern  = "*",
  callback = safe(function()
    -- Reserved for plugin-reload cleanup. node.lua owns the WS lifecycle.
  end),
})

-- ---------------------------------------------------------------------------
-- Hint
-- ---------------------------------------------------------------------------
-- A short one-liner the first time the plugin loads so users know it's
-- installed but not yet configured. Helps avoid "I installed it, nothing
-- happened" confusion.
do
  local already_hinted = vim.g.nvimclaw_hinted == 1
  if not already_hinted then
    vim.g.nvimclaw_hinted = 1
    vim.api.nvim_create_autocmd("VimEnter", {
      pattern = "*",
      once    = true,
      callback = function()
        -- Defer the echo so it doesn't fight with startup screen messages.
        vim.schedule(function()
          if vim.g.nvimclaw_setup == 1 then return end
          vim.api.nvim_echo({
            { "[nvimclaw] plugin loaded. Run :OpenClawSetup to initialize.", "None" },
          }, false, {})
        end)
      end,
    })
  end
end
