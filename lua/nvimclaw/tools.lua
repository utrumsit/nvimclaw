--[[
  tools.lua — implementations of every nvim.* command the agent can invoke.

  This is the Vim-side half of the OpenClaw node capability.
  When the agent runs `openclaw nodes invoke --node <id> --command nvim.ex.substitute`,
  node.lua receives a `node.invoke.request` event, looks up the matching
  registered handler here, runs it, and replies with `node.invoke.result`.

  Tier gating
  -----------
  Two tiers:
    * safe       — read-only; available after pairing by default
    * privileged — mutating; requires tools.tier == "privileged"

  When tools.tier is "safe", privileged tools return
    { ok = false, error = { code = "tier_denied", message = "tool requires privileged tier" } }

  Optimistic locking
  ------------------
  Every mutating tool accepts `expected_changedtick`. Tools that act on a
  line range also accept `expected_line_hash` (SHA-256 hex of the current
  lines in the affected range, joined by "\n"). On mismatch, the tool
  returns:
    { ok = false, error = { code = "conflict",
                            current_changedtick = N,
                            current_line_hash  = "...",
                            sample_lines       = { ... } } }
  so the agent can re-read, re-hash, and retry.

  Strict param validation
  -----------------------
  Every tool rejects unknown params with
    { ok=false, error={code="unknown_param", param=...} }

  Handler return contract
  -----------------------
  Every handler returns ONE of:
    { ok = true,  result = <data> }
    { ok = false, error  = { code = "...", ... } }
  node.lua wraps this into the protocol envelope. We never throw across
  the handler boundary (pcall is in the dispatcher).
]]

local M = {}

-- ---------------------------------------------------------------------------
-- Tool registry
-- ---------------------------------------------------------------------------
-- Maps "nvim.<command>" → { tier, handler, description }.
-- Populated by register_all() and add(). The Node layer also keeps its own
-- registry for dispatch; ours is the source of truth for tier + description.

local registry = {}   -- name (without "nvim.") → entry
local target_buf = nil -- last normal file buffer, used when chat has focus
local buffer_path

local TIER_SAFE       = "safe"
local TIER_PRIVILEGED = "privileged"

-- ---------------------------------------------------------------------------
-- Public: register_all
-- ---------------------------------------------------------------------------

--- Register every built-in nvim.* tool with the Node.
-- Call this from init.lua's setup() after the Node is up.
-- @param node table the Node module (must have node.register_tool)
function M.register_all(node)
  -- ---- Safe tier (read-only) -------------------------------------------
  M.add(node, "buffer.current",    "Describe the current window's active buffer", TIER_SAFE, M._tool_buffer_current)
  M.add(node, "buffer.read",       "Read a buffer's contents", TIER_SAFE, M._tool_buffer_read)
  M.add(node, "search",            "Search for a pattern in a file", TIER_SAFE, M._tool_search)
  M.add(node, "cursor.get",        "Get cursor position", TIER_SAFE, M._tool_cursor_get)
  M.add(node, "selection.get",     "Get current visual selection", TIER_SAFE, M._tool_selection_get)
  M.add(node, "diagnostics.get",   "Get LSP/quickfix diagnostics for a buffer", TIER_SAFE, M._tool_diagnostics_get)
  M.add(node, "describe",          "Describe plugin capabilities (plugin_version, tools, surface_id, ...)", TIER_SAFE, M._tool_describe)

  -- ---- Privileged tier (mutating) --------------------------------------
  M.add(node, "buffer.write",         "Replace full-buffer contents (alias for buffer.replace_lines 0,-1)", TIER_PRIVILEGED, M._tool_buffer_write_alias)
  M.add(node, "buffer.replace_lines", "Replace a range of lines in a buffer", TIER_PRIVILEGED, M._tool_buffer_replace_lines)
  M.add(node, "buffer.open",          "Open a file in a buffer", TIER_PRIVILEGED, M._tool_buffer_open)
  M.add(node, "buffer.reload",        "Reload a buffer from disk (:edit! or :checktime)", TIER_PRIVILEGED, M._tool_buffer_reload)
  M.add(node, "ex.substitute",        "Run :s/pat/repl/flags on a buffer (supports dry_run)", TIER_PRIVILEGED, M._tool_ex_substitute)
  M.add(node, "ex.command",           "Run a Vim Ex command (optional confirm prompt)", TIER_PRIVILEGED, M._tool_ex_command)
  M.add(node, "cursor.set",           "Set cursor position", TIER_PRIVILEGED, M._tool_cursor_set)
end

--- Add a single tool to the registry and (optionally) the Node.
-- Exposed so users can extend the tool surface from their own config:
--   require("nvimclaw.tools").add(require("nvimclaw.node"),
--     "my.custom.thing", "Description", "safe", function(params) ... end)
-- @param node      table  the Node module (may be nil to register locally only)
-- @param name      string tool name WITHOUT the "nvim." prefix
-- @param desc      string human-readable description
-- @param tier      string "safe" | "privileged"
-- @param handler   function(params) -> {ok=..., result=...} | {ok=false, error=...}
function M.add(node, name, desc, tier, handler)
  registry[name] = { tier = tier, handler = handler, description = desc }

  -- Tell the Node about it too. The Node's register_tool may not exist
  -- yet (we land files in stages), so we pcall.
  if node and node.register_tool then
    pcall(node.register_tool, {
      name        = "nvim." .. name,
      description = desc,
      tier        = tier,
      -- params_schema is declarative; the Node serializes it for `describe`.
      -- We pass an empty table here — strict validation lives in _invoke.
      params_schema = {},
      handler     = function(params)
        return M._invoke(name, params)
      end,
    })
  end
end

--- Remove a tool from the registry.
-- @param name string tool name WITHOUT the "nvim." prefix
function M.remove(name)
  registry[name] = nil
  local Node_module = package.loaded["nvimclaw.node"]
  if Node_module and Node_module.unregister_tool then
    pcall(Node_module.unregister_tool, "nvim." .. name)
  end
end

--- Return a snapshot of all registered tools, grouped by tier.
-- Used by nvim.describe.
-- @return table { safe = {...names...}, privileged = {...names...} }
function M.list_tools()
  local safe, priv = {}, {}
  for name, entry in pairs(registry) do
    local n = "nvim." .. name
    if entry.tier == TIER_PRIVILEGED then
      table.insert(priv, n)
    else
      table.insert(safe, n)
    end
  end
  table.sort(safe)
  table.sort(priv)
  return { safe = safe, privileged = priv }
end

-- ---------------------------------------------------------------------------
-- Internal dispatcher
-- ---------------------------------------------------------------------------

--- Validate params strictly against a known set, then dispatch.
-- Wraps the handler in pcall so a buggy handler can never crash the plugin.
-- @param name string tool name WITHOUT the "nvim." prefix
-- @param params table user-supplied params
-- @return table {ok=..., result=...} | {ok=false, error=...}
function M._invoke(name, params)
  local entry = registry[name]
  if not entry then
    return { ok = false, error = { code = "unknown_command", command = "nvim." .. tostring(name) } }
  end

  -- Tier gate.
  local Config = require("nvimclaw.config")
  local cfg = Config.current()
  if entry.tier == TIER_PRIVILEGED and cfg.tools.tier ~= TIER_PRIVILEGED then
    return { ok = false, error = { code = "tier_denied", message = "tool requires privileged tier" } }
  end

  -- Strict param validation. We compare against a known key set per tool.
  local known = M._known_params(name)
  if known then
    if type(params) ~= "table" then params = {} end
    for k, _ in pairs(params) do
      if not known[k] then
        return { ok = false, error = { code = "unknown_param", param = k } }
      end
    end
  end

  -- Run handler with pcall.
  local ok, result = pcall(entry.handler, params or {})
  if not ok then
    return { ok = false, error = { code = "internal_error", message = tostring(result) } }
  end
  -- Defensive: handler must return a table.
  if type(result) ~= "table" then
    return { ok = false, error = { code = "internal_error", message = "handler did not return a table" } }
  end
  return result
end

--- Known-params whitelist per tool.
-- Anything not in this set triggers unknown_param rejection.
function M._known_params(name)
  local sets = {
    ["buffer.current"]      = { include_content = true, max_lines = true },
    ["buffer.read"]         = { path = true, buffer_id = true },
    ["search"]              = { path = true, pattern = true },
    ["cursor.get"]          = { path = true, buffer_id = true },
    ["selection.get"]       = {},
    ["diagnostics.get"]     = { path = true },
    ["describe"]            = {},
    ["buffer.write"]        = { path = true, buffer_id = true, content = true, lines = true, expected_changedtick = true, expected_line_hash = true },
    ["buffer.replace_lines"] = { path = true, buffer_id = true, start = true, ["end"] = true, lines = true, expected_changedtick = true, expected_line_hash = true },
    ["buffer.open"]         = { path = true },
    ["buffer.reload"]       = { path = true, buffer_id = true, force = true },
    ["ex.substitute"]       = { path = true, buffer_id = true, pattern = true, replacement = true, flags = true, expected_changedtick = true, expected_line_hash = true, dry_run = true },
    ["ex.command"]          = { cmd = true, confirm = true, preserve_layout = true },
    ["cursor.set"]          = { path = true, buffer_id = true, line = true, col = true },
  }
  return sets[name]
end

-- ---------------------------------------------------------------------------
-- Path / buffer helpers
-- ---------------------------------------------------------------------------

local function canonical_path(path)
  local expanded = vim.fn.fnamemodify(path, ":p")
  return vim.loop.fs_realpath(expanded) or expanded
end

--- Resolve a user-supplied path against workspace_root.
-- Absolute paths must fall inside workspace_root, else nil.
-- Relative paths are joined to workspace_root.
-- Empty/nil path returns workspace_root itself.
-- @param path string
-- @return string|nil absolute path, or nil if denied
function M._resolve_path(path)
  local Config = require("nvimclaw.config")
  local workspace = Config.current().workspace_root or vim.fn.getcwd()

  if path == nil or path == "" then
    return vim.fn.fnamemodify(workspace, ":p")
  end

  local ws = canonical_path(workspace)

  -- vim.fn.isabsolutepath is not always present; check for a leading / instead.
  local is_abs = tostring(path):sub(1, 1) == "/"
  if is_abs then
    -- vim.fn.fnamemodify(path, ":p") normalizes the path.
    local resolved = canonical_path(path)
    -- Absolute paths must live inside workspace_root.
    -- We require a trailing separator on workspace_root to avoid prefix false-positives
    -- (e.g. /home/karl/projects vs /home/karl/projects-old).
    local ws_prefix = ws
    if ws_prefix:sub(-1) ~= "/" then ws_prefix = ws_prefix .. "/" end
    if resolved == ws or resolved:sub(1, #ws_prefix) == ws_prefix then
      return resolved
    end
    return nil
  end

  -- Relative paths resolve against workspace_root.
  local prefix = ws
  if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
  return canonical_path(prefix .. path)
end

--- Find a buffer handle by absolute path.
-- Returns nil if no listed buffer matches.
-- @param resolved_path string absolute path
-- @return number|nil buffer handle
function M._find_buffer_by_path(resolved_path)
  local target = canonical_path(resolved_path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and canonical_path(name) == target then
        return buf
      end
    end
  end
  return nil
end

local function buffer_from_id(buffer_id)
  local buf = tonumber(buffer_id)
  if not buf or buf < 1 then
    return nil
  end
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then
    return nil
  end
  return buf
end

local function is_chat_buffer(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return false
  end
  return vim.api.nvim_buf_get_name(buf) == "nvimclaw://chat"
end

local function is_agent_target_buffer(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then
    return false
  end
  if is_chat_buffer(buf) then
    return false
  end
  if vim.api.nvim_buf_get_option(buf, "buftype") ~= "" then
    return false
  end
  if vim.api.nvim_buf_get_name(buf) ~= "" then
    return true
  end
  if vim.api.nvim_buf_get_option(buf, "modified") then
    return true
  end
  if vim.api.nvim_buf_line_count(buf) > 1 then
    return true
  end
  local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
  return line ~= ""
end

local function window_for_buffer(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

local function snapshot_windows()
  local snapshot = {
    current_win = vim.api.nvim_get_current_win(),
    windows = {},
  }
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local item = {
        win = win,
        buf = vim.api.nvim_win_get_buf(win),
        cursor = nil,
      }
      pcall(function()
        item.cursor = vim.api.nvim_win_get_cursor(win)
      end)
      table.insert(snapshot.windows, item)
    end
  end
  return snapshot
end

local function restore_windows(snapshot)
  if type(snapshot) ~= "table" then
    return
  end
  for _, item in ipairs(snapshot.windows or {}) do
    if vim.api.nvim_win_is_valid(item.win) and vim.api.nvim_buf_is_valid(item.buf) then
      if vim.api.nvim_win_get_buf(item.win) ~= item.buf then
        pcall(vim.api.nvim_win_set_buf, item.win, item.buf)
      end
      if item.cursor then
        pcall(vim.api.nvim_win_set_cursor, item.win, item.cursor)
      end
    end
  end
  if snapshot.current_win and vim.api.nvim_win_is_valid(snapshot.current_win) then
    pcall(vim.api.nvim_set_current_win, snapshot.current_win)
  end
end

function M.note_current_buffer()
  local buf = vim.api.nvim_get_current_buf()
  if is_agent_target_buffer(buf) then
    target_buf = buf
  end
end

function M._agent_target()
  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_win_get_buf(current_win)
  if is_agent_target_buffer(current_buf) then
    target_buf = current_buf
    return current_buf, current_win, false
  end

  if is_agent_target_buffer(target_buf) then
    return target_buf, window_for_buffer(target_buf), true
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if is_agent_target_buffer(buf) then
      target_buf = buf
      return buf, win, true
    end
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_agent_target_buffer(buf) then
      target_buf = buf
      return buf, window_for_buffer(buf), true
    end
  end

  return current_buf, current_win, false
end

function M._target_buffer_from_params(params, default_to_agent_target)
  params = params or {}

  if params.buffer_id ~= nil then
    local buf = buffer_from_id(params.buffer_id)
    if not buf then
      return nil, nil, { code = "buffer_not_found", buffer_id = params.buffer_id }
    end
    return buf, buffer_path(buf), nil
  end

  if params.path ~= nil and params.path ~= "" then
    local resolved = M._resolve_path(params.path)
    if not resolved then
      return nil, nil, { code = "path_denied", path = params.path }
    end
    local buf = M._find_buffer_by_path(resolved)
    if not buf then
      return nil, resolved, { code = "buffer_not_found", path = resolved }
    end
    return buf, resolved, nil
  end

  if default_to_agent_target then
    local buf = M._agent_target()
    return buf, buffer_path(buf), nil
  end

  return nil, nil, { code = "unknown_param", param = "path or buffer_id required" }
end

--- SHA-256 hex of a list of lines, joined by "\n".
-- Matches the agent-side expected_line_hash calculation.
function M._hash_lines(lines)
  local Util = require("nvimclaw.util")
  return Util.sha256_hex(table.concat(lines, "\n"))
end

--- Build the conflict response shape used by every mutating tool.
-- @param buf       number buffer handle
-- @param extra     table|nil extra fields (e.g. current_line_hash)
-- @return table {ok=false, error={...}}
function M._conflict_response(buf, extra)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, math.min(20, vim.api.nvim_buf_line_count(buf)), false)
  local err = {
    code = "conflict",
    current_changedtick = vim.api.nvim_buf_get_changedtick(buf),
    current_line_hash = M._hash_lines(lines),
    sample_lines = lines,
  }
  if type(extra) == "table" then
    for k, v in pairs(extra) do err[k] = v end
  end
  return { ok = false, error = err }
end

--- Verify expected_changedtick; return a conflict response on mismatch.
function M._check_changedtick(buf, expected)
  if expected == nil then return nil end
  local current = vim.api.nvim_buf_get_changedtick(buf)
  if current ~= expected then
    return M._conflict_response(buf)
  end
  return nil
end

--- Verify expected_line_hash against the given lines; conflict on mismatch.
function M._check_line_hash(lines, expected)
  if expected == nil then return nil end
  local current = M._hash_lines(lines)
  if current ~= expected then
    return { ok = false, error = {
      code = "conflict",
      current_line_hash = current,
    }}
  end
  return nil
end

buffer_path = function(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return ""
  end
  return vim.fn.fnamemodify(name, ":p")
end

local function buffer_metadata(buf, win, include_content, max_lines)
  local path = buffer_path(buf)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local cursor = nil
  if win and vim.api.nvim_win_is_valid(win) then
    local cur = vim.api.nvim_win_get_cursor(win)
    cursor = { line = cur[1], col = cur[2] + 1 }
  end

  local result = {
    buffer_id = buf,
    path = path,
    name = vim.api.nvim_buf_get_name(buf),
    filetype = vim.api.nvim_buf_get_option(buf, "filetype"),
    buftype = vim.api.nvim_buf_get_option(buf, "buftype"),
    modified = vim.api.nvim_buf_get_option(buf, "modified"),
    readonly = vim.api.nvim_buf_get_option(buf, "readonly"),
    line_count = line_count,
    changedtick = vim.api.nvim_buf_get_changedtick(buf),
    cursor = cursor,
  }

  if include_content then
    local limit = tonumber(max_lines) or line_count
    local lines = vim.api.nvim_buf_get_lines(buf, 0, math.min(line_count, limit), false)
    result.lines = lines
    result.content = table.concat(lines, "\n")
    result.truncated = line_count > #lines
  end

  return result
end

-- ---------------------------------------------------------------------------
-- Safe-tier handlers
-- ---------------------------------------------------------------------------

--- nvim.buffer.current
-- Params: { include_content?, max_lines? }
-- Returns: { ok=true, result={path, buffer_id, cursor, changedtick, ...} }
function M._tool_buffer_current(params)
  params = params or {}
  local buf, win, using_target = M._agent_target()
  local result = buffer_metadata(buf, win, params.include_content == true, params.max_lines)
  result.target_source = using_target and "last_file_buffer" or "current_window"
  return { ok = true, result = result }
end

--- nvim.buffer.read
-- Params: { path }
-- Returns: { ok=true, result={path, content, lines, line_count, changedtick, language} }
function M._tool_buffer_read(params)
  params = params or {}
  local buf, resolved, err = M._target_buffer_from_params(params, true)
  if err then
    if err.code == "buffer_not_found" and err.path then
      resolved = err.path
    else
      return { ok = false, error = err }
    end
  end

  if not buf then
    -- File exists on disk but no buffer yet: load it.
    if vim.fn.filereadable(resolved) == 0 then
      return { ok = false, error = { code = "file_missing", path = resolved } }
    end
    buf = vim.fn.bufadd(resolved)
    if buf == 0 then
      return { ok = false, error = { code = "buffer_not_found", path = resolved } }
    end
    pcall(vim.fn.bufload, buf)
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return { ok = true, result = {
    buffer_id   = buf,
    path        = resolved,
    content     = table.concat(lines, "\n"),
    lines       = lines,
    line_count  = #lines,
    changedtick = vim.api.nvim_buf_get_changedtick(buf),
    language    = vim.api.nvim_buf_get_option(buf, "filetype"),
  }}
end

--- nvim.search
-- Params: { path, pattern }
-- Returns: { ok=true, result={matches=[{line, col, text}], count=N} }
function M._tool_search(params)
  local resolved = M._resolve_path(params.path)
  if not resolved then
    return { ok = false, error = { code = "path_denied", path = params.path } }
  end
  if vim.fn.filereadable(resolved) == 0 then
    return { ok = false, error = { code = "file_missing", path = resolved } }
  end

  local lines = vim.fn.readfile(resolved)
  local matches = {}
  for i, line in ipairs(lines) do
    local search_from = 1
    while true do
      local s, e = string.find(line, params.pattern, search_from)
      if not s then break end
      table.insert(matches, { line = i, col = s, text = line })
      search_from = e + 1
      -- Safety net: if pattern is empty string, string.find loops forever.
      if e < s then break end
    end
  end

  return { ok = true, result = { matches = matches, count = #matches } }
end

--- nvim.cursor.get
-- Params: { path } (optional — defaults to current buffer)
-- Returns: { ok=true, result={line, col, buffer_id} }
function M._tool_cursor_get(params)
  local buf, win
  if params.path and params.path ~= "" then
    local err
    buf, _, err = M._target_buffer_from_params(params, false)
    if err then return { ok = false, error = err } end
    win = window_for_buffer(buf)
  elseif params.buffer_id ~= nil then
    local err
    buf, _, err = M._target_buffer_from_params(params, false)
    if err then return { ok = false, error = err } end
    win = window_for_buffer(buf)
  else
    buf, win = M._agent_target()
  end

  local cur = { 1, 0 }
  if win and vim.api.nvim_win_is_valid(win) then
    -- nvim_win_get_cursor returns {row (1-based), col (0-based)}.
    cur = vim.api.nvim_win_get_cursor(win)
  end
  return { ok = true, result = {
    line = cur[1],
    col  = cur[2] + 1,
    buffer_id = buf,
  }}
end

--- nvim.selection.get
-- Params: {}
-- Returns: { ok=true, result={start, finish, lines, mode} }
function M._tool_selection_get(_)
  local mode = vim.fn.visualmode()
  if mode == "" then
    -- No prior selection — return empty.
    return { ok = true, result = {
      start = nil, finish = nil, lines = {}, mode = "none",
    }}
  end

  -- Get the marks set by the last visual selection.
  local s_pos = vim.fn.getpos("v")
  local e_pos = vim.fn.getpos(".")
  local s_line, s_col = s_pos[2], s_pos[3]
  local e_line, e_col = e_pos[2], e_pos[3]

  -- Normalize start <= finish.
  if s_line > e_line or (s_line == e_line and s_col > e_col) then
    s_line, e_line = e_line, s_line
    s_col, e_col = e_col, s_col
  end

  local lines = vim.api.nvim_buf_get_lines(0, s_line - 1, e_line, false)
  -- Trim the first/last line to the column boundaries if same line.
  if #lines == 1 then
    lines[1] = lines[1]:sub(s_col, e_col)
  else
    if lines[1] then lines[1] = lines[1]:sub(s_col) end
    if lines[#lines] then lines[#lines] = lines[#lines]:sub(1, e_col) end
  end

  return { ok = true, result = {
    start  = { line = s_line, col = s_col },
    finish = { line = e_line, col = e_col },
    lines  = lines,
    mode   = mode,  -- "v", "V", "" (block)
  }}
end

--- nvim.diagnostics.get
-- Params: { path }
-- Returns: { ok=true, result={diagnostics=[...] } }
function M._tool_diagnostics_get(params)
  local resolved = M._resolve_path(params.path)
  if not resolved then
    return { ok = false, error = { code = "path_denied", path = params.path } }
  end
  local buf = M._find_buffer_by_path(resolved)
  if not buf then
    return { ok = false, error = { code = "buffer_not_found", path = resolved } }
  end
  local diags = vim.diagnostic.get(buf)
  return { ok = true, result = { diagnostics = diags } }
end

--- nvim.describe
-- Params: {}
-- Returns: { ok=true, result={plugin_version, protocol_version, tools, surface_id,
--                              node_id, gateway, cwd, workspace_root} }
function M._tool_describe(_)
  local Config = require("nvimclaw.config")
  local cfg = Config.current()

  -- Node may or may not be ready; pcall each accessor.
  local surface_id, node_id = nil, nil
  pcall(function()
    local Node = require("nvimclaw.node")
    if Node.surface_id then surface_id = Node.surface_id() end
    if Node.node_id then node_id = Node.node_id() end
  end)

  return { ok = true, result = {
    plugin_version   = "0.1.0",
    protocol_version = 1,
    tools            = M.list_tools(),
    surface_id       = surface_id,
    node_id          = node_id,
    gateway          = cfg.gateway,
    cwd              = vim.fn.getcwd(),
    workspace_root   = cfg.workspace_root,
  }}
end

-- ---------------------------------------------------------------------------
-- Privileged-tier handlers
-- ---------------------------------------------------------------------------

--- nvim.buffer.write  (alias for full-buffer replace_lines)
-- Params: { path, content | lines, expected_changedtick?, expected_line_hash? }
-- This is intentionally redundant with replace_lines so editor-trained agents
-- can call it. Internally it IS replace_lines(0, -1).
function M._tool_buffer_write_alias(params)
  local new_lines
  if params.lines then
    new_lines = params.lines
  elseif params.content ~= nil then
    -- Split content into lines, preserving trailing-newline semantics.
    new_lines = vim.split(params.content, "\n", { plain = true })
  else
    return { ok = false, error = { code = "unknown_param", param = "(missing content or lines)" } }
  end

  return M._tool_buffer_replace_lines({
    path                 = params.path,
    buffer_id            = params.buffer_id,
    start                = 0,
    ["end"]              = -1,
    lines                = new_lines,
    expected_changedtick = params.expected_changedtick,
    expected_line_hash   = params.expected_line_hash,
  })
end

--- nvim.buffer.replace_lines
-- Params: { path, start, end, lines, expected_changedtick?, expected_line_hash? }
-- start and end are 0-based half-open, matching nvim_buf_set_lines.
-- Note: "end" is a Lua keyword, so we receive it as params["end"].
function M._tool_buffer_replace_lines(params)
  local buf, _, err = M._target_buffer_from_params(params, false)
  if err then return { ok = false, error = err } end

  -- Validate range params.
  if type(params.start) ~= "number" or type(params["end"]) ~= "number" then
    return { ok = false, error = { code = "unknown_param", param = "start/end must be numbers" } }
  end
  if type(params.lines) ~= "table" then
    return { ok = false, error = { code = "unknown_param", param = "lines must be an array" } }
  end

  local start_line = params.start
  local end_line   = params["end"]

  -- changedtick guard.
  local conflict = M._check_changedtick(buf, params.expected_changedtick)
  if conflict then return conflict end

  -- For range-targeted mutators, line_hash is computed over the to-be-replaced range.
  -- nvim_buf_set_lines uses half-open [start, end), so we read [start, end).
  local current_lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line, false)
  conflict = M._check_line_hash(current_lines, params.expected_line_hash)
  if conflict then return conflict end

  -- Apply.
  local ok = pcall(vim.api.nvim_buf_set_lines, buf, start_line, end_line, false, params.lines)
  if not ok then
    return { ok = false, error = { code = "internal_error", message = "nvim_buf_set_lines failed" } }
  end

  return { ok = true, result = {
    changedtick = vim.api.nvim_buf_get_changedtick(buf),
    line_hash   = M._hash_lines(params.lines),
    line_count  = #params.lines,
  }}
end

--- nvim.buffer.open
-- Params: { path }
-- Returns: { ok=true, result={buffer_id, path} }
function M._tool_buffer_open(params)
  local resolved = M._resolve_path(params.path)
  if not resolved then
    return { ok = false, error = { code = "path_denied", path = params.path } }
  end
  if vim.fn.filereadable(resolved) == 0 then
    return { ok = false, error = { code = "file_missing", path = resolved } }
  end

  -- Use a safe edit command via vim.cmd; :edit is the standard way.
  pcall(vim.cmd, "edit " .. vim.fn.fnameescape(resolved))

  local buf = vim.fn.bufadd(resolved)
  return { ok = true, result = {
    buffer_id = buf,
    path      = resolved,
  }}
end

--- nvim.buffer.reload
-- Params: { path?, force? }
-- force=true runs :edit! for the target buffer. Otherwise :checktime.
function M._tool_buffer_reload(params)
  params = params or {}
  local buf, _, err = M._target_buffer_from_params(params, true)
  if err then return { ok = false, error = err } end

  if params.force == true then
    pcall(vim.api.nvim_buf_call, buf, function() vim.cmd("edit!") end)
  else
    pcall(vim.api.nvim_buf_call, buf, function() vim.cmd("checktime") end)
  end

  return { ok = true, result = buffer_metadata(buf, window_for_buffer(buf), false, nil) }
end

--- nvim.ex.substitute
-- Params: { path, pattern, replacement, flags?, expected_changedtick?, expected_line_hash?, dry_run? }
-- Returns (apply): { ok=true, result={matches, replaced, changedtick, line_hash} }
-- Returns (dry_run): { ok=true, result={matches, sample_lines, line_hash (of CURRENT buffer)} }
function M._tool_ex_substitute(params)
  if not params.pattern then
    return { ok = false, error = { code = "unknown_param", param = "pattern" } }
  end

  local buf, _, err = M._target_buffer_from_params(params, true)
  if err then return { ok = false, error = err } end

  -- changedtick guard.
  local conflict = M._check_changedtick(buf, params.expected_changedtick)
  if conflict then return conflict end

  -- Read the entire buffer; substitute line-by-line. (We don't use :%s on
  -- the buffer directly because that mutates state and we want to support
  -- dry_run + sample_lines reporting.)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local current_line_hash = M._hash_lines(lines)

  -- line_hash guard: hash is over the whole buffer (substitute's range
  -- is the whole buffer unless the caller narrows it).
  conflict = M._check_line_hash(lines, params.expected_line_hash)
  if conflict then return conflict end

  local replacement = params.replacement or ""
  local flags       = params.flags or ""

  local new_lines = {}
  local changed_indexes = {}
  for i, line in ipairs(lines) do
    local replaced = vim.fn.substitute(line, params.pattern, replacement, flags)
    if replaced ~= line then
      table.insert(changed_indexes, i)
    end
    table.insert(new_lines, replaced)
  end

  local match_count = #changed_indexes

  -- Build sample_lines for both apply and dry_run.
  local sample = {}
  for _, idx in ipairs(changed_indexes) do
    -- Cap at 10 samples for sanity.
    if #sample >= 10 then break end
    table.insert(sample, { line = idx, before = lines[idx], after = new_lines[idx] })
  end

  if params.dry_run then
    -- Preflight only: do NOT mutate the buffer.
    return { ok = true, result = {
      matches     = match_count,
      sample_lines = sample,
      line_hash   = current_line_hash,   -- hash of CURRENT (pre-substitute) state
    }}
  end

  -- Apply.
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, new_lines)

  return { ok = true, result = {
    matches    = match_count,
    replaced   = match_count,
    changedtick = vim.api.nvim_buf_get_changedtick(buf),
    line_hash  = M._hash_lines(new_lines),
  }}
end

--- nvim.ex.command
-- Params: { cmd, confirm? }
-- If confirm is true, prompt the user via vim.fn.confirm before executing.
function M._tool_ex_command(params)
  if not params.cmd or type(params.cmd) ~= "string" then
    return { ok = false, error = { code = "unknown_param", param = "cmd" } }
  end

  if params.confirm then
    local choice = vim.fn.confirm("nvimclaw: run command?\n\n" .. params.cmd, "&Yes\n&No", 2)
    if choice ~= 1 then
      return { ok = false, error = { code = "declined", message = "user declined" } }
    end
  end

  local preserve_layout = params.preserve_layout ~= false
  local layout = preserve_layout and snapshot_windows() or nil

  -- Run via nvim_exec2 so we capture output.
  local ok, exec_result = pcall(vim.api.nvim_exec2, params.cmd, { output = true })
  if preserve_layout then
    restore_windows(layout)
  end
  if not ok then
    return { ok = false, error = { code = "ex_failed", message = tostring(exec_result) } }
  end
  return { ok = true, result = {
    output = exec_result.output or "",
    code   = exec_result.code or 0,
  }}
end

--- nvim.cursor.set
-- Params: { path, line, col }
function M._tool_cursor_set(params)
  if type(params.line) ~= "number" or type(params.col) ~= "number" then
    return { ok = false, error = { code = "unknown_param", param = "line/col must be numbers" } }
  end

  local buf, _, err = M._target_buffer_from_params(params, true)
  if err then return { ok = false, error = err } end
  local win = window_for_buffer(buf)
  if not win then
    return { ok = false, error = { code = "buffer_not_visible", buffer_id = buf } }
  end

  -- nvim_win_set_cursor wants {row (1-based), col (0-based)}.
  local ok = pcall(vim.api.nvim_win_set_cursor, win, { params.line, math.max(0, params.col - 1) })
  if not ok then
    return { ok = false, error = { code = "internal_error", message = "nvim_win_set_cursor failed" } }
  end

  return { ok = true, result = { line = params.line, col = params.col } }
end

return M
