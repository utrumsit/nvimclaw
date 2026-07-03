--[[
  config.lua — defaults table + apply/current API

  This module is the single source of truth for nvimclaw's runtime configuration.

  Why a separate config module?
  -----------------------------
  The plugin uses sensible defaults so it works with zero config
  after `:Lazy install nvimclaw`. Every other module reads from
  `require("nvimclaw.config").current()` rather than holding its own copy of
  the config. That way `:OpenClawTools privileged` and `setup({...})` both
  take effect immediately without each module needing to subscribe to updates.

  Public API:
    Config.apply(user_opts)  -- deep-merge user opts onto defaults, store result
    Config.current()         -- return the merged config (live, not a snapshot)
    Config.reset()           -- restore defaults (test helper)
]]

local M = {}

-- ---------------------------------------------------------------------------
-- Defaults
-- ---------------------------------------------------------------------------
-- IMPORTANT: These are LITERAL defaults. workspace_root is resolved lazily
-- inside apply() because vim.fn.getcwd() is meaningful at setup time, not at
-- module-load time.

local defaults = {
  -- Gateway endpoint. Loopback is the safe default.
  gateway = {
    host = "127.0.0.1",
    port = 18789,
    tls = false,
    contextPath = "",
  },

  -- Session to send surface messages to.
  -- Main gateway session key. Current OpenClaw uses agent:<agentId>:main.
  session = "agent:main:main",

  -- Global keymap that opens the chat buffer.
  -- Honors lazy.nvim-style remaps if the user re-binds it.
  keymap = "<space>oc",

  -- Auto-attach behavior when chat opens:
  --   "buffer"    attach current buffer path/line_count/changedtick
  --   "selection" attach current visual selection (or buffer if no selection)
  --   "none"      don't attach anything; user types freeform
  attach = "buffer",

  -- Chat UI geometry.
  chat = {
    side = "right",   -- "right" | "left" | "bottom"
    width = 0.4,      -- fraction of columns (for vertical splits)
  },

  -- Tool tier. "safe" by default; "privileged" unlocks mutating tools.
  -- Toggled at runtime via :OpenClawTools privileged.
  tools = {
    tier = "safe",
  },

  -- Filesystem paths. Both are tilde-expanded at use-time.
  identity_path = "~/.local/state/nvimclaw/identity.json",
  log_path = "~/.local/state/nvimclaw/nvimclaw.log",

  -- Receive timeout for session-send request/response.
  receive_timeout_ms = 15000,

  -- Workspace boundary for tool paths. Relative tool paths resolve inside
  -- this root; paths outside it return {error = "path_denied"}.
  -- Set in apply() to vim.fn.getcwd() if the user didn't specify.
  workspace_root = nil,

  -- Disable the plugin's default keymaps (<space>oc, <space>oC).
  -- Defaults to false; users opt out via setup({disable_default_keymaps = true}).
  disable_default_keymaps = false,

  -- Log level for nvimclaw's structured log. "info" by default; "debug" verbose.
  log_level = "info",

  -- Include message bodies / file snippets in logs. Default false keeps logs
  -- redacted unless the user explicitly opts into verbose debugging.
  debug_content = false,
}

-- The live, merged config. nil until apply() runs.
local merged = nil

-- ---------------------------------------------------------------------------
-- Deep merge
-- ---------------------------------------------------------------------------
-- Merges `override` on top of `base`, recursively for tables, replacing for
-- scalars. Tables are NOT mutated; a new merged table is returned.
--
-- Why custom merge instead of vim.tbl_deep_extend?
--   * We want to preserve defaults for keys absent in the user config even
--     when the user passes a partial sub-table (e.g. setup({gateway = {port = 19000}}))
--     should still inherit host = "127.0.0.1", tls = false, contextPath = "".
--   * vim.tbl_deep_extend("force", ...) does that, but it's nice to keep the
--     merge logic obvious and local so non-Lua readers can follow it.

local function deep_merge(base, override)
  -- If either side isn't a table, the override wins.
  if type(base) ~= "table" or type(override) ~= "table" then
    return override
  end

  local result = {}
  for k, v in pairs(base) do
    result[k] = v
  end
  for k, v in pairs(override) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = deep_merge(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

local function parse_gateway_url(url)
  if type(url) ~= "string" or url == "" then return nil end
  local scheme, rest = url:match("^([%w+.-]+)://(.+)$")
  if not scheme or not rest or scheme ~= "ws" then return nil end

  local authority, path = rest:match("^([^/]*)(/.*)$")
  if not authority then
    authority = rest
    path = ""
  end

  local host, port
  if authority:sub(1, 1) == "[" then
    host, port = authority:match("^%[([^%]]+)%]:(%d+)$")
    if not host then host = authority:match("^%[([^%]]+)%]$") end
  else
    host, port = authority:match("^([^:]+):(%d+)$")
    if not host then host = authority end
  end
  if not host or host == "" then return nil end

  return {
    host = host,
    port = tonumber(port) or 18789,
    tls = false,
    contextPath = path or "",
  }
end

local function read_openclaw_gateway_config()
  local path = vim.fn.expand("~/.openclaw/openclaw.json")
  if vim.fn.filereadable(path) ~= 1 then return nil end

  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()

  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then return nil end
  local gateway = data.gateway
  if type(gateway) ~= "table" or type(gateway.remote) ~= "table" then return nil end

  return parse_gateway_url(gateway.remote.url)
end

-- ---------------------------------------------------------------------------
-- Lazy default resolvers
-- ---------------------------------------------------------------------------
-- Some defaults depend on Neovim state (cwd). We resolve them once, in apply().

local function resolve_lazy_defaults(cfg)
  -- workspace_root: fall back to cwd if the user didn't supply one.
  if cfg.workspace_root == nil then
    cfg.workspace_root = vim.fn.getcwd()
  end
  return cfg
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Apply user configuration on top of defaults.
-- Replaces any previously applied config. Idempotent within a session.
-- @param user_config table|nil  user-supplied config (typically from setup())
function M.apply(user_config)
  user_config = user_config or {}
  local base = defaults
  if user_config.gateway == nil then
    local openclaw_gateway = read_openclaw_gateway_config()
    if openclaw_gateway then
      base = deep_merge(defaults, { gateway = openclaw_gateway })
    end
  end
  local fresh = deep_merge(base, user_config)
  merged = resolve_lazy_defaults(fresh)
end

--- Return the current merged config.
-- Returns defaults if apply() hasn't been called yet, so other modules
-- (chat, tools, node) can safely read config at any time.
function M.current()
  if merged == nil then
    -- Lazy fallback: apply defaults so callers don't crash.
    merged = resolve_lazy_defaults(deep_merge(defaults, {}))
  end
  return merged
end

--- Reset to defaults. Used by tests.
function M.reset()
  merged = nil
end

--- Return the literal defaults table (without user overrides).
-- Exposed for tests and for users who want to introspect.
function M.defaults()
  return defaults
end

M._parse_gateway_url = parse_gateway_url

return M
