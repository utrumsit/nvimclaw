--[[
  init.lua — public entry point for the nvimclaw plugin.

  This is what `:OpenClawSetup` and lazy.nvim's `require("nvimclaw").setup({...})`
  eventually call. It wires together:
    1. config.lua          — store user opts
    2. node.lua            — gateway connection (separate module, not written here)
    3. chat.lua            — chat buffer UI
    4. tools.lua           — nvim.* tool registrations

  Public API:
    require("nvimclaw").setup(opts)   — initialize the plugin
    require("nvimclaw").status()     — return {state, node_id, device_id, session}

  Design notes:
    * `setup()` is idempotent. Calling it twice with different opts applies
      the second call. This matches `lazy.nvim`'s expectations.
    * Keybindings are set here (not in plugin/nvimclaw.lua) so they can
      honor the `disable_default_keymaps` config flag. The plugin script
      only registers commands and autocmds that have no config dependency.
    * We require("nvimclaw.node") lazily inside setup()/status() so that
      loading nvimclaw without a setup call doesn't fail just because
      node.lua has an unrelated bug.
]]

local M = {}
local chat_event_handler = nil
local checktime_autocmd_registered = false
local target_buffer_autocmd_registered = false

-- ---------------------------------------------------------------------------
-- setup
-- ---------------------------------------------------------------------------

--- Initialize the nvimclaw plugin.
-- @param opts table|nil user config; merged onto defaults via Config.apply
function M.setup(opts)
  opts = opts or {}
  vim.g.nvimclaw_setup = 1

  -- 1. Apply config first, so other modules see the merged values.
  local Config = require("nvimclaw.config")
  Config.apply(opts)
  local config = Config.current()

  -- 2. Bring up the node (gateway connection). This is best-effort: if the
  --    node module isn't written yet (we're landing files in stages), we
  --    log and continue so chat and tools still load.
  local Node = require("nvimclaw.node")
  local ok, err = pcall(Node.start)
  if not ok then
    local Util = require("nvimclaw.util")
    Util.log("warn", "node.start failed: %s", tostring(err))
  end

  -- 3. Register default keybindings unless the user opted out.
  if not config.disable_default_keymaps then
    M._register_default_keymaps()
  end

  -- 4. Auto-open the chat buffer if attach mode is buffer or selection.
  --    "none" means: don't open chat on setup; user opens it manually.
  if config.attach == "buffer" or config.attach == "selection" then
    local Chat = require("nvimclaw.chat")
    pcall(Chat.maybe_open)
  end

  -- 5. Auto-register built-in tools with the Node.
  --    This is a no-op until Node.start succeeds; tools register regardless
  --    because the Node keeps a registry that's consulted on every invoke.
  local Tools = require("nvimclaw.tools")
  pcall(Tools.register_all, Node)
  pcall(Node.start_node)

  if not checktime_autocmd_registered then
    checktime_autocmd_registered = true
    M._register_checktime_autocmd()
  end
  if not target_buffer_autocmd_registered then
    target_buffer_autocmd_registered = true
    M._register_target_buffer_autocmd()
  end

  -- 6. Wire node events into the chat buffer so assistant responses render.
  --    We do this last so chat can already render the "connecting" state.
  pcall(function()
    if chat_event_handler and Node.off_event then
      Node.off_event(chat_event_handler)
    end
    chat_event_handler = function(event_name, payload)
      local Chat = require("nvimclaw.chat")
      Chat.handle_event(event_name, payload)
    end
    Node.on_event(chat_event_handler)
  end)
end

function M._register_checktime_autocmd()
  local group = vim.api.nvim_create_augroup("nvimclaw_checktime", { clear = true })
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
    group = group,
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      if vim.api.nvim_buf_get_option(buf, "buftype") ~= "" then return end
      if vim.api.nvim_buf_get_option(buf, "modified") then return end
      pcall(vim.cmd, "checktime")
    end,
    desc = "nvimclaw: notice external file changes for unmodified buffers",
  })
end

function M._register_target_buffer_autocmd()
  local group = vim.api.nvim_create_augroup("nvimclaw_target_buffer", { clear = true })
  vim.api.nvim_create_autocmd({
    "BufEnter",
    "WinEnter",
    "CursorMoved",
    "CursorMovedI",
    "TextChanged",
    "TextChangedI",
    "InsertLeave",
    "BufWritePost",
  }, {
    group = group,
    callback = function(args)
      pcall(function()
        require("nvimclaw.tools").note_buffer(args.buf)
      end)
    end,
    desc = "nvimclaw: remember the last normal or edited buffer for agent tools",
  })
end

-- ---------------------------------------------------------------------------
-- Internal: register the default global keymaps
-- ---------------------------------------------------------------------------
-- These are *global* (set on the normal mode namespace) and respect
-- `disable_default_keymaps`. The chat buffer's *local* keymaps
-- (<CR>, <C-c>, etc.) are registered inside chat.lua's buffer setup.

local function _register_default_keymaps()
  -- <space>oc → open chat
  vim.keymap.set("n", "<space>oc", function()
    require("nvimclaw.chat").open()
  end, { desc = "nvimclaw: open chat", silent = true })

  -- <space>oC → show status (capital C for "see")
  vim.keymap.set("n", "<space>oC", function()
    local s = require("nvimclaw").status()
    local lines = {
      "nvimclaw status",
      "  chat:      " .. tostring(s.state),
      "  node:      " .. tostring(s.node_state),
      "  node_id:   " .. tostring(s.node_id),
      "  device_id: " .. tostring(s.device_id),
      "  auth:      " .. tostring(s.gateway_auth_token),
      "  device:    " .. tostring(s.device_token),
      "  session:   " .. tostring(s.session),
    }
    vim.api.nvim_echo({ { table.concat(lines, "\n"), "None" } }, false, {})
  end, { desc = "nvimclaw: show status", silent = true })

  vim.keymap.set("n", "<space>os", function()
    vim.cmd("OpenClawStatus")
  end, { desc = "nvimclaw: show status", silent = true })

  vim.keymap.set("n", "<space>ot", function()
    local Config = require("nvimclaw.config")
    local tier = ((Config.current().tools or {}).tier == "privileged") and "safe" or "privileged"
    vim.cmd("OpenClawTools " .. tier)
  end, { desc = "nvimclaw: toggle tool tier", silent = true })

  vim.keymap.set("n", "<space>op", function()
    local Node = require("nvimclaw.node")
    if Node.state() == "connected" or Node.state() == "connecting" or Node.state() == "handshaking" then
      Node.stop()
    else
      Node.start()
    end
  end, { desc = "nvimclaw: pause/resume connection", silent = true })
end

-- Expose for testability (m.prefixed with underscore = internal).
M._register_default_keymaps = _register_default_keymaps
M._register_checktime_autocmd = M._register_checktime_autocmd
M._register_target_buffer_autocmd = M._register_target_buffer_autocmd

-- ---------------------------------------------------------------------------
-- status
-- ---------------------------------------------------------------------------

--- Return a snapshot of plugin state.
-- Used by :OpenClawStatus, the <space>oC keymap, and the chat buffer's
-- status indicator. Always returns a table (never nil) so callers can
-- safely index into it.
-- @return table {state, node_id, device_id, session}
function M.status()
  local Config = require("nvimclaw.config")
  local config = Config.current()

  -- Node may not have started yet; guard each accessor with pcall.
  local state, node_state, node_id, device_id, gateway_auth_token, device_token = "disconnected", "disconnected", nil, nil, nil, nil
  pcall(function()
    local Node = require("nvimclaw.node")
    if Node.state then state = Node.state() end
    if Node.node_state then node_state = Node.node_state() end
    if Node.node_id then node_id = Node.node_id() end
    if Node.device_id then device_id = Node.device_id() end
    if Node.device_token then device_token = Node.device_token() and "yes" or "no" end
    if Node.info then
      local info = Node.info()
      gateway_auth_token = info.gateway_auth_token
    end
  end)

  return {
    state = state,
    node_state = node_state,
    node_id = node_id,
    device_id = device_id,
    gateway_auth_token = gateway_auth_token,
    device_token = device_token,
    session = config.session,
    gateway = config.gateway,
  }
end

return M
