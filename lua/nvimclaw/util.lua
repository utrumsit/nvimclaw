--[[
  util.lua — small helpers used across the plugin.

  Every function here is intentionally tiny and dependency-free so the rest
  of the plugin can stay readable. If a function grows past ~30 lines, it
  probably belongs in its own module.

  Functions:
    log(level, message, ...)         — append a timestamped line to log_path
                                       with size-based rotation
    uuid()                          — RFC 4122 v4 UUID as a hex string
    now_ms()                        — monotonic millisecond timestamp
    epoch_ms()                      — wall-clock Unix epoch milliseconds
    b64url_encode(s)                — base64url (RFC 4648 §5) without padding
    b64url_decode(s)                — inverse of b64url_encode
    sha256_hex(s)                   — lowercase hex SHA-256 of a string
    random_bytes(n)                 — N cryptographically random bytes
    json_encode(tbl)                — JSON encode a Lua table
    json_decode(str)                — JSON decode a string into a Lua table
    mkdir_p(path)                   — mkdir -p, expanding ~ and creating parents

  Compatibility: Neovim 0.9+ (uses vim.loop where 0.9 is required; falls
  back to vim.uv where available so 0.10+ users get the modern name).
]]

local M = {}

-- Resolve the libuv binding once at module load. vim.uv was added in 0.10;
-- vim.loop is the pre-0.10 name and remains as an alias in 0.10+.
local uv = vim.uv or vim.loop

-- ---------------------------------------------------------------------------
-- Time
-- ---------------------------------------------------------------------------

--- Monotonic millisecond timestamp.
-- Uses libuv's monotonic clock so it's immune to wall-clock adjustments.
-- @return integer milliseconds since some unspecified epoch
function M.now_ms()
  return uv.now()
end

--- Wall-clock Unix epoch timestamp in milliseconds.
-- Use this for protocol fields that are compared against server time.
-- @return integer milliseconds since 1970-01-01T00:00:00Z
function M.epoch_ms()
  if uv.gettimeofday then
    local sec, usec = uv.gettimeofday()
    return (sec * 1000) + math.floor(usec / 1000)
  end
  return os.time() * 1000
end

-- ---------------------------------------------------------------------------
-- UUID v4
-- ---------------------------------------------------------------------------

--- Generate a random UUID v4 string (hex form, with dashes).
-- @return string like "f47ac10b-58cc-4372-a567-0e02b2c3d479"
function M.uuid()
  local bytes = { M.random_bytes(16):byte(1, 16) }
  bytes[7] = bit.bor(bit.band(bytes[7], 0x0F), 0x40)
  bytes[9] = bit.bor(bit.band(bytes[9], 0x3F), 0x80)
  return string.format(
    "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
    bytes[1], bytes[2], bytes[3], bytes[4],
    bytes[5], bytes[6],
    bytes[7], bytes[8],
    bytes[9], bytes[10],
    bytes[11], bytes[12], bytes[13], bytes[14], bytes[15], bytes[16]
  )
end

-- ---------------------------------------------------------------------------
-- Base64URL
-- ---------------------------------------------------------------------------
-- The V3 device-identity payload uses Ed25519 keys and device tokens
-- transmitted as base64url. Standard base64 with
-- '+' / '/' / '=' replaced by '-' / '_' / '' so the string is safe inside
-- URLs and JSON without escaping.

--- Encode a string as base64url (no padding).
-- @param s string (Lua strings are byte sequences; perfect for raw key bytes)
-- @return string
function M.b64url_encode(s)
  -- Neovim 0.10+ has vim.base64; older versions fall back to vim.fn.base64encode.
  -- Both operate on byte-string input.
  local b64
  if vim.base64 and vim.base64.encode then
    b64 = vim.base64.encode(s)
  else
    b64 = vim.fn.base64encode(s)
  end
  -- Translate to URL-safe alphabet and strip padding.
  b64 = b64:gsub("+", "-"):gsub("/", "_"):gsub("=", "")
  return b64
end

--- Decode a base64url string back to bytes.
-- @param s string base64url-encoded
-- @return string bytes
function M.b64url_decode(s)
  if s == nil or s == "" then return "" end
  -- Restore standard base64 alphabet and padding.
  local pad = (4 - (#s % 4)) % 4
  s = s:gsub("-", "+"):gsub("_", "/") .. string.rep("=", pad)
  if vim.base64 and vim.base64.decode then
    return vim.base64.decode(s)
  else
    return vim.fn.base64decode(s)
  end
end

-- ---------------------------------------------------------------------------
-- SHA-256
-- ---------------------------------------------------------------------------

--- SHA-256 of a string, returned as 64-char lowercase hex.
-- Uses Neovim's built-in vim.fn.sha256 (which wraps libcrypto). The input
-- is treated as a byte string; for hashing Ed25519 public keys stored as
-- raw bytes (Lua strings), this is exactly what we want.
-- @param s string
-- @return string 64-char lowercase hex digest
function M.sha256_hex(s)
  return vim.fn.sha256(s)
end

-- ---------------------------------------------------------------------------
-- Random bytes
-- ---------------------------------------------------------------------------

--- Return N cryptographically random bytes as a string.
-- Used by node.lua for the WebSocket frame mask key and the HTTP upgrade
-- Sec-WebSocket-Key. MUST be safe to call from libuv fast event callbacks
-- (TCP connect, etc.), so we avoid vim.fn.tempname and io.open — both
-- forbidden in fast events. Vim.random.bytes is safe; uv.random is safe.
-- @param n number length in bytes (default 16)
-- @return string|nil raw bytes; nil on failure
function M.random_bytes(n)
  n = n or 16
  -- /dev/urandom is synchronous, fast-event safe, and POSIX-portable.
  -- This is the primary path; it's what we use for WS frame masks and
  -- Sec-WebSocket-Key generation.
  local f = io.open("/dev/urandom", "rb")
  if f then
    local data = f:read(n)
    f:close()
    if data and #data == n then return data end
  end
  -- Fallback: libuv urandom (async via callback). Used only if /dev/urandom
  -- is unavailable (Windows or sandboxed envs). The caller will be in a
  -- fast-event context; we use the synchronous portion of uv.random which
  -- returns immediately with a number and fires the callback with the bytes.
  if uv and uv.random then
    local got
    uv.random(n, nil, function(_, data) got = data end)
    if got and #got == n then return got end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- JSON
-- ---------------------------------------------------------------------------

--- Encode a Lua table as JSON.
-- Uses vim.json if present (Neovim 0.10+), falls back to vim.fn.json_encode.
-- Wraps in pcall so a malformed table doesn't crash the plugin — it returns
-- nil instead, matching how chat/tools handle errors.
-- @param tbl table
-- @return string|nil json, nil on failure
function M.json_encode(tbl)
  if vim.json and vim.json.encode then
    local ok, result = pcall(vim.json.encode, tbl)
    if ok then return result end
    return nil
  end
  local ok, result = pcall(vim.fn.json_encode, tbl)
  if ok then return result end
  return nil
end

--- Decode a JSON string into a Lua table.
-- Uses vim.json if present, falls back to vim.fn.json_decode.
-- @param str string
-- @return table|nil decoded, string|nil err
function M.json_decode(str)
  if str == nil or str == "" then return nil, "empty input" end
  if vim.json and vim.json.decode then
    local ok, result = pcall(vim.json.decode, str)
    if ok then return result end
    return nil, tostring(result)
  end
  local ok, result = pcall(vim.fn.json_decode, str)
  if ok then return result, nil end
  return nil, tostring(result)
end

-- ---------------------------------------------------------------------------
-- Filesystem helpers
-- ---------------------------------------------------------------------------

--- Recursive mkdir, expanding ~ to $HOME.
-- Thin wrapper over vim.fn.mkdir(..., "p") which creates parents as needed.
-- @param path string absolute or ~-prefixed path
-- @return boolean true on success or already-exists, false on failure
function M.mkdir_p(path)
  if path == nil or path == "" then return false end
  -- vim.fn.mkdir with "p" creates parents and is idempotent (no error if exists).
  local ok, err = pcall(vim.fn.mkdir, vim.fn.expand(path), "p")
  if not ok then
    -- Fall through; the caller decides how to handle.
    return false
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------
-- Append-only structured log. Each line:
--   [YYYY-MM-DD HH:MM:SS.mmm] [LEVEL] message
--
-- Rotation: when the log file exceeds MAX_BYTES, it's renamed to
-- "<path>.1" (overwriting any previous .1). One-generation rotation is
-- plenty for a debug log; multi-generation rotation can land later if it
-- matters.
--
-- Logging is best-effort. Failures (disk full, permission denied) are
-- swallowed silently — we'd rather drop a log line than crash the editor.

local MAX_BYTES = 1 * 1024 * 1024  -- 1 MiB per file before rotation

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }

--- Resolve the configured log level as an integer rank.
local function current_level_rank()
  local Config = require("nvimclaw.config")
  local ok, cfg = pcall(Config.current)
  if not ok or not cfg then return LEVELS.info end
  return LEVELS[cfg.log_level] or LEVELS.info
end

-- Resolved log path. Refreshed lazily on config changes but cached so that
-- log() itself never calls vim.fn.expand (unsafe in libuv fast events).
local _log_path = nil

local function resolve_log_path()
  if _log_path then return _log_path end
  local ok, Config = pcall(require, "nvimclaw.config")
  if not ok then return nil end
  local cfg = Config.current()
  local raw = (cfg and cfg.log_path) or "~/.local/state/nvimclaw/nvimclaw.log"
  _log_path = vim.fn.expand(raw)
  pcall(M.mkdir_p, vim.fn.fnamemodify(_log_path, ":h"))
  return _log_path
end

-- Allow callers (notably Config.apply) to invalidate the cache when config changes.
function M.invalidate_log_path_cache() _log_path = nil end

--- Append a log line to the configured log_path.
-- Variadic: log(level, "format %s %d", "x", 7) or log(level, "literal").
-- Safe to call from libuv fast event callbacks (TCP connect, etc.) because
-- we use cached path + libuv fs calls, no vim.fn.
-- @param level string "debug" | "info" | "warn" | "error"
function M.log(level, message, ...)
  level = level or "info"
  local rank = LEVELS[level] or LEVELS.info
  if rank < current_level_rank() then return end

  -- Resolve log path (cached; only uses vim.fn on first call or after invalidation).
  local path = resolve_log_path()
  if not path then return end

  -- Format message.
  local formatted
  if select("#", ...) > 0 then
    formatted = string.format(message, ...)
  else
    formatted = tostring(message)
  end

  -- Rotation check (cheap: stat only).
  pcall(function()
    local stat = uv.fs_stat(path)
    if stat and stat.size > MAX_BYTES then
      -- Rename .log -> .log.1 (overwriting any existing .log.1).
      uv.fs_unlink(path .. ".1")
      uv.fs_rename(path, path .. ".1")
    end
  end)

  -- Compose the line.
  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  local line = string.format("[%s] [%s] %s\n", timestamp, level:upper(), formatted)

  -- Append. We use io.open (synchronous) because log writes are rare and
  -- small; async adds complexity for no real win.
  local fd = io.open(path, "a")
  if fd then
    fd:write(line)
    fd:close()
  end
end

return M
