--[[
nvimclaw.node — WebSocket client to OpenClaw Gateway with V3 device auth.

This is the heart of the plugin. It:
  - Manages a single WebSocket connection to the gateway
  - Performs the V3 device-auth handshake (Ed25519 over a pipe-delimited payload)
  - Persists the device identity and deviceToken between sessions
  - Exposes `session_send` (surface) and `invoke_result` (node) APIs
  - Dispatches `node.invoke.request` events to registered tool handlers
  - Reconnects with exponential backoff; replays in-flight session_send calls

Protocol source: openclaw/openclaw (github.com/openclaw/openclaw).

This file is intentionally heavy on comments so the protocol flow stays auditable.
]]

local uv = vim.loop or vim.uv
local Config = require("nvimclaw.config")
local Util = require("nvimclaw.util")

local M = {}

-- Forward declaration of emit so M.start / M.stop / set_state can use it
-- before its full definition appears later in the file. We declare the
-- local and immediately assign a no-op implementation; the real one below
-- overwrites it before any code runs (the file is parsed top-to-bottom).
local emit = function(event_name, payload)
  -- placeholder; replaced below
end

-- Forward declarations for internal helpers used by M.start() before their
-- full definitions appear later in the file. Each is assigned nil here and
-- replaced with the real function by the `local function name()` definitions
-- below (Lua parses the file top-to-bottom, so the real bodies land before
-- any code actually runs).
local load_or_create_identity
local persist_device_token
local open_websocket
local _parse_ws_frames_inner
local parse_ws_frames
local send_connect
local on_ws_close
local setup_ping_timer
local read_gateway_token
local send_http_upgrade
local read_http_response
local read_ws_frames
local handle_text_frame
local handle_event
local handle_response
local handle_invoke_request
local encode_ws_frame
local send_frame
local schedule_reconnect
local open_node_websocket
local send_node_http_upgrade
local read_node_http_response
local read_node_ws_frames
local parse_node_ws_frames
local handle_node_text_frame
local handle_node_event
local handle_node_response
local send_node_connect
local on_node_ws_close
local schedule_node_reconnect
local send_node_frame
local openssl_exe
local websocket_path

-- =============================================================================
-- Internal state
-- =============================================================================

-- The "public" state string. The state machine below drives it.
M._state = "disconnected"

-- Everything else is private. Encapsulated in this table so reload doesn't
-- trample on a running connection (we don't currently support hot reload, but
-- the encapsulation makes the code easier to reason about).
local S = {
  ws = nil,                     -- uv TCP handle for the current connection
  frame_buffer = "",            -- raw bytes received from the gateway (WS frames split)
  node_ws = nil,                -- second WS connection for role=node tool invocation
  node_frame_buffer = "",       -- raw bytes for the node-role WS
  node_state = "disconnected",  -- node-role connection state
  node_reconnect_delay = 1,     -- node-role reconnect backoff
  node_reconnect_enabled = true,
  node_close_code = nil,
  node_close_reason = nil,
  node_hello_ok_seen = false,
  nonce = nil,                  -- current connect-challenge nonce
  node_nonce = nil,             -- current node-role connect-challenge nonce
  ts = nil,                     -- current connect-challenge timestamp
  node_ts = nil,                -- current node-role connect-challenge timestamp
  private_key_path = nil,       -- filesystem path to identity PEM
  public_key_b64url = nil,      -- base64url of raw 32-byte Ed25519 public key
  device_id = nil,              -- hex sha256 of raw public key
  device_token = nil,           -- current device token (from latest hello-ok)
  reconnect_delay = 1,          -- exponential backoff seconds (1, 2, 4, ..., 30)
  reconnect_enabled = true,     -- false after stop(); suppress auto-reconnect
  reconnect_timer = nil,        -- pending operator reconnect timer
  node_reconnect_timer = nil,   -- pending node-role reconnect timer
  event_subscribers = {},       -- list of fn(event_name, payload)
  tools = {},                   -- name -> {description, tier, handler}
  pending_sends = {},           -- idempotency_key -> {sent_at_ms, opts, ack_received}
  pending_requests = {},        -- request id -> {method, sent_at_ms}
  pending_invokes = {},         -- invoke id -> {sent_at_ms, opts}  (we don't currently track these; node.invoke.result is fire-and-forget)
  handshake_timer = nil,        -- timer for handshake timeout
  ping_timer = nil,             -- timer for ping
  close_code = nil,             -- last close code (for diagnostics)
  close_reason = nil,           -- last close reason
  hello_ok_seen = false,        -- flag: have we ever completed a hello-ok?
  identity_path = nil,          -- expanded path to identity metadata JSON
  openssl_path = nil,           -- resolved openssl executable path
}

local function shellescape(value)
  return vim.fn.shellescape(tostring(value))
end

openssl_exe = function()
  if S.openssl_path then
    return S.openssl_path
  end

  local candidates = {}
  local exepath = vim.fn.exepath("openssl")
  if exepath and exepath ~= "" then
    table.insert(candidates, exepath)
  end
  table.insert(candidates, "/opt/homebrew/bin/openssl")
  table.insert(candidates, "/usr/local/bin/openssl")
  table.insert(candidates, "/usr/bin/openssl")

  for _, path in ipairs(candidates) do
    if vim.fn.executable(path) == 1 then
      S.openssl_path = path
      return path
    end
  end

  S.openssl_path = "openssl"
  return S.openssl_path
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Begin the connection lifecycle. Idempotent.
function M.start()
  if M.state() ~= "disconnected" and M.state() ~= "reconnecting" then
    return  -- already connecting/connected
  end
  if S.reconnect_timer then
    pcall(function() S.reconnect_timer:stop() end)
    pcall(function() S.reconnect_timer:close() end)
    S.reconnect_timer = nil
  end
  S.reconnect_enabled = true
  load_or_create_identity()
  M.set_state("connecting")
  emit("state", M.state())
  open_websocket()
end

--- Begin the node-role connection lifecycle for nvim.* tool invocation.
function M.start_node()
  if S.node_state ~= "disconnected" and S.node_state ~= "reconnecting" then
    return
  end
  if S.node_reconnect_timer then
    pcall(function() S.node_reconnect_timer:stop() end)
    pcall(function() S.node_reconnect_timer:close() end)
    S.node_reconnect_timer = nil
  end
  S.node_reconnect_enabled = true
  load_or_create_identity()
  S.node_state = "connecting"
  emit("node.state", S.node_state)
  open_node_websocket()
end

--- Close the connection and stop auto-reconnect.
function M.stop()
  S.reconnect_enabled = false
  S.node_reconnect_enabled = false
  if S.ws then
    pcall(function() S.ws:close() end)
  end
  if S.node_ws then
    pcall(function() S.node_ws:close() end)
  end
  if S.reconnect_timer then
    pcall(function() S.reconnect_timer:stop() end)
    pcall(function() S.reconnect_timer:close() end)
    S.reconnect_timer = nil
  end
  if S.node_reconnect_timer then
    pcall(function() S.node_reconnect_timer:stop() end)
    pcall(function() S.node_reconnect_timer:close() end)
    S.node_reconnect_timer = nil
  end
  M.set_state("disconnected")
  S.node_state = "disconnected"
  emit("state", M.state())
  emit("node.state", S.node_state)
end

--- Subscribe to events. Events: see "Events" section below.
function M.on_event(callback)
  table.insert(S.event_subscribers, callback)
end

function M.off_event(callback)
  for i, cb in ipairs(S.event_subscribers) do
    if cb == callback then
      table.remove(S.event_subscribers, i)
      return
    end
  end
end

--- Send a user turn to a session. Returns {idempotency_key} on success.
function M.session_send(opts)
  -- opts = { key, content, attachments?, idempotency_key?, thinking? }
  if M.state() ~= "connected" then
    return nil, "not connected (state: " .. M.state() .. ")"
  end
  if not opts.key or not opts.content then
    return nil, "missing required field: key or content"
  end
  local id = opts.idempotency_key or Util.uuid()
  local req_id = Util.uuid()
  local frame = {
    type = "req",
    id = req_id,
    method = "sessions.send",
    params = {
      key = opts.key,
      message = opts.content,
      attachments = opts.attachments,
      thinking = opts.thinking,
      timeoutMs = opts.timeout_ms,
      idempotencyKey = id,
    },
  }
  Util.log("info", "sending sessions.send key=" .. tostring(opts.key) .. " reqId=" .. req_id)
  local ok, err = send_frame(vim.json.encode(frame))
  if not ok then
    return nil, err
  end
  S.pending_requests[req_id] = {
    method = "sessions.send",
    sent_at_ms = Util.now_ms(),
    idempotency_key = id,
  }
  S.pending_sends[id] = {
    sent_at_ms = Util.now_ms(),
    opts = opts,
    ack_received = false,
  }
  return { idempotency_key = id, runId = nil }  -- runId arrives in the ack response
end

--- Reply to a node.invoke.request from the gateway. Fire-and-forget; no ack.
function M.invoke_result(opts)
  -- opts = { id, ok, payload?, payloadJSON?, error? }
  if S.node_state ~= "connected" and M.state() ~= "connected" then
    return false, "not connected"
  end
  local frame = {
    type = "req",
    id = Util.uuid(),
    method = "node.invoke.result",
    params = {
      id = opts.id,
      nodeId = S.device_id,
      ok = opts.ok,
      payload = opts.payload,
      payloadJSON = opts.payloadJSON,
      error = opts.error,
    },
  }
  if S.node_state == "connected" then
    return send_node_frame(vim.json.encode(frame))
  end
  return send_frame(vim.json.encode(frame))
end

--- Register a tool the agent can invoke via nvim.<name>.
function M.register_tool(opts)
  if not opts.name or not opts.handler then
    error("register_tool requires name and handler")
  end
  S.tools[opts.name] = {
    name = opts.name,
    description = opts.description or "",
    tier = opts.tier or "safe",
    handler = opts.handler,
  }
end

function M.unregister_tool(name)
  S.tools[name] = nil
end

function M.list_tools()
  local result = {}
  for _, t in pairs(S.tools) do
    table.insert(result, { name = t.name, description = t.description, tier = t.tier })
  end
  return result
end

-- Public state introspection (for :OpenClawStatus)
--
-- We keep the canonical state in `M._state` and expose `M.state()` as
-- the accessor so callers don't need to remember the parens. Setting
-- state goes through `M.set_state()` so we always emit the "state" event.
M._state = "disconnected"
function M.state() return M._state end
function M.set_state(s)
  if M._state == s then return end
  M._state = s
  emit("state", s)
end

function M.device_id() return S.device_id end
function M.node_id() return S.device_id end  -- we don't have a separate nodeId; deviceId is the durable id
function M.node_state() return S.node_state end
function M.device_token() return S.device_token end
function M.public_key() return S.public_key_b64url end
function M.surface_id() return S.surface_id end

-- =============================================================================
-- Events emitted
-- =============================================================================
--
--   "state"                       new state string
--   "connect.challenge"           { nonce, ts }
--   "connect.hello_ok"            full hello-ok payload
--   "connect.closed"              { code, reason }
--   "connect.failed"              { error, retryable }
--   "chat"                        { runId, sessionKey, seq, state, message, errorMessage? }
--   "agent"                       { runId, seq, stream, ts, data }   (if subscribed)
--   "node.invoke.request"         { id, nodeId, command, paramsJSON, timeoutMs, idempotencyKey }
--   "presence"                    presence update
--   "health"                      health update
--   ...                           any other broadcast event

emit = function(event_name, payload)
  -- Subscriber callbacks may call vim API (buffer manipulation, window
  -- management, etc.), which is unsafe in libuv fast event contexts.
  -- Defer all subscriber calls to the main loop. This is a simple,
  -- one-place fix that protects every subscriber.
  vim.schedule(function()
    for _, cb in ipairs(S.event_subscribers) do
      local ok, err = pcall(cb, event_name, payload)
      if not ok then
        Util.log("error", "event handler for " .. event_name .. " threw: " .. tostring(err))
      end
    end
  end)
end

-- =============================================================================
-- Identity persistence
-- =============================================================================
--
-- We store the keypair as a PEM file at identity.json + ".pem" (mode 0600)
-- and metadata at identity.json (mode 0600). The PEM is what `openssl pkeyutl`
-- reads. The metadata is for fast introspection.
--
-- We also derive `deviceId` (hex sha256 of the raw 32-byte public key) and
-- `publicKey` (base64url of the same 32 bytes) and cache them in S.

local function raw_pub_from_pem(pem_path)
  -- Extract the raw 32-byte public key from an Ed25519 private key PEM.
  -- The SPKI form is 44 bytes; the last 32 are the raw key.
  -- We use io.popen (standard Lua) which is safe in fast events, unlike vim.fn.system.
  local cmd = shellescape(openssl_exe())
    .. " pkey -in " .. shellescape(pem_path)
    .. " -pubout -outform DER 2>/dev/null | base64 | tr -d '\\n'"
  local handle = io.popen(cmd)
  if not handle then return nil, "io.popen failed" end
  local out = handle:read("*a")
  local success, reason, code = handle:close()
  if not success or (type(code) == "number" and code ~= 0) then
    return nil, "openssl pkey failed: " .. tostring(out)
  end
  -- Decode base64 to raw bytes. Prefer vim.base64 (Neovim 0.10+) over manual decode.
  local der_bytes
  if vim.base64 and vim.base64.decode then
    local ok, decoded = pcall(vim.base64.decode, out)
    if ok then der_bytes = decoded end
  end
  if not der_bytes then
    -- Fallback: shell to openssl for decode (also using io.popen)
    local cmd_decode = "printf %s " .. shellescape(out) .. " | base64 -d | xxd -p -c 1000"
    local handle2 = io.popen(cmd_decode)
    if handle2 then
      local hex = handle2:read("*a")
      handle2:close()
      if hex then
        der_bytes = (hex:gsub("%s", "")):gsub("..", function(c) return string.char(tonumber(c, 16)) end)
      end
    end
  end
  if not der_bytes or #der_bytes < 32 then
    return nil, "DER output too short: " .. (der_bytes and #der_bytes or 0) .. " bytes"
  end
  -- The SPKI DER for Ed25519 is exactly 44 bytes: 12-byte prefix + 32-byte raw key.
  return der_bytes:sub(#der_bytes - 31)
end

load_or_create_identity = function()
  local cfg = Config.current()
  local identity_path = vim.fn.expand(cfg.identity_path)
  S.identity_path = identity_path
  local dir = vim.fn.fnamemodify(identity_path, ":h")
  vim.fn.mkdir(dir, "p")

  local pem_path = identity_path .. ".pem"

  -- If we have a metadata JSON, try to load it. Otherwise generate fresh.
  local need_generate = true
  if vim.fn.filereadable(identity_path) == 1 then
    local f = io.open(identity_path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      local ok, data = pcall(vim.json.decode, content)
      if ok and type(data) == "table" and data.publicKey and data.deviceId then
        S.public_key_b64url = data.publicKey
        S.device_id = data.deviceId
        S.device_token = data.deviceToken
        -- Verify the PEM still exists
        if vim.fn.filereadable(pem_path) == 1 then
          S.private_key_path = pem_path
          need_generate = false
        end
      end
    end
  end

  if need_generate then
    -- Generate new keypair via openssl
    Util.log("info", "generating new Ed25519 device identity at " .. pem_path)
    vim.fn.system({ openssl_exe(), "genpkey", "-algorithm", "Ed25519", "-out", pem_path })
    if vim.v.shell_error ~= 0 or vim.fn.filereadable(pem_path) ~= 1 then
      Util.log("error", "failed to generate Ed25519 keypair")
      return
    end
    vim.fn.setfperm(pem_path, "r--------")

    -- Derive public key
    local raw_pub, err = raw_pub_from_pem(pem_path)
    if not raw_pub then
      Util.log("error", "failed to extract public key: " .. tostring(err))
      return
    end
    S.public_key_b64url = Util.b64url_encode(raw_pub)
    -- sha256 of raw 32 bytes, hex
    S.device_id = Util.sha256_hex(raw_pub)
    S.private_key_path = pem_path

    -- Persist metadata
    local data = {
      version = 1,
      deviceId = S.device_id,
      publicKey = S.public_key_b64url,
      -- We do NOT persist the private key here; it lives in the PEM file.
      deviceToken = nil,  -- populated on first hello-ok
      createdAtMs = Util.epoch_ms(),
    }
    local f = io.open(identity_path, "w")
    if f then
      f:write(vim.json.encode(data))
      f:close()
      vim.fn.setfperm(identity_path, "r--------")
    end
  end

  Util.log("info", string.format("identity ready: deviceId=%s publicKey=%s...",
    S.device_id, (S.public_key_b64url or ""):sub(1, 12)))
end

persist_device_token = function()
  if not S.device_token then return end
  local identity_path = S.identity_path
  if not identity_path or identity_path == "" then return end
  local f = io.open(identity_path, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then return end
  data.deviceToken = S.device_token
  data.lastConnectedAtMs = Util.epoch_ms()
  local of = io.open(identity_path, "w")
  if of then
    of:write(vim.json.encode(data))
    of:close()
    pcall(uv.fs_chmod, identity_path, 256)
  end
end

-- =============================================================================
-- V3 device-auth payload + signing
-- =============================================================================
--
-- V3 format (from openclaw source):
--   v3|<deviceId>|<clientId>|<clientMode>|<role>|<scopes>|<signedAtMs>|<token>|<nonce>|<platform>|<deviceFamily>
--
-- The signature is Ed25519 over the UTF-8 bytes of this string.
-- The gateway builds the same string from the connect params and verifies
-- byte-for-byte. Fields must match exactly (esp. platform and deviceFamily,
-- which must match connectParams.client.{platform,deviceFamily}).

local function build_v3_payload(opts)
  -- opts = { scopes_csv, signed_at_ms, token, nonce, platform, device_family }
  return table.concat({
    "v3",
    S.device_id,
    opts.client_id or "cli",
    opts.client_mode or "cli",
    opts.role or "operator",
    opts.scopes_csv or "operator.read,operator.write",
    tostring(opts.signed_at_ms),
    opts.token or "",
    opts.nonce,
    opts.platform or "macos",
    opts.device_family or "",
  }, "|")
end

local function sign_v3_payload(payload)
  local tmp_payload = os.tmpname()
  local tmp_sig = os.tmpname()
  local f = io.open(tmp_payload, "wb")
  if not f then return nil, "could not write temp payload" end
  f:write(payload)
  f:close()

  local cmd = table.concat({
    shellescape(openssl_exe()),
    "pkeyutl",
    "-sign",
    "-inkey",
    shellescape(S.private_key_path),
    "-in",
    shellescape(tmp_payload),
    "-out",
    shellescape(tmp_sig),
    "2>&1",
  }, " ")
  local handle = io.popen(cmd)
  if not handle then
    os.remove(tmp_payload)
    os.remove(tmp_sig)
    return nil, "io.popen failed"
  end
  local output = handle:read("*a")
  local success, reason, code = handle:close()
  os.remove(tmp_payload)
  if not success or (type(code) == "number" and code ~= 0) then
    os.remove(tmp_sig)
    return nil, "openssl pkeyutl sign failed (exit "
      .. tostring(code or reason)
      .. "): "
      .. tostring(output or "")
  end
  local sf = io.open(tmp_sig, "rb")
  if not sf then
    os.remove(tmp_sig)
    return nil, "could not read signature"
  end
  local sig = sf:read("*a")
  sf:close()
  os.remove(tmp_sig)
  if #sig ~= 64 then
    return nil, "unexpected signature length: " .. #sig
  end
  return sig
end

-- =============================================================================
-- WebSocket: connect, frames, send/receive
-- =============================================================================

open_websocket = function()
  if S.ws then
    pcall(function() S.ws:close() end)
    S.ws = nil
  end
  local cfg = Config.current()
  local host = cfg.gateway.host
  local port = cfg.gateway.port
  local path = cfg.gateway.contextPath
  if type(host) ~= "string" or host == "" or type(port) ~= "number" then
    schedule_reconnect("invalid gateway config: host/port missing")
    return
  end

  local tcp = uv.new_tcp()
  if not tcp then
    schedule_reconnect("could not create TCP handle")
    return
  end
  S.ws = tcp
  S.frame_buffer = ""

  tcp:connect(host, port, function(err)
    if err then
      Util.log("warn", "TCP connect failed: " .. err)
      schedule_reconnect("tcp: " .. err)
      return
    end
    send_http_upgrade(tcp, host, port, path)
  end)
end

websocket_path = function(path)
  if type(path) ~= "string" or path == "" then return "/" end
  if path:sub(1, 1) ~= "/" then return "/" .. path end
  return path
end

send_http_upgrade = function(tcp, host, port, path)
  local key = vim.base64.encode(Util.random_bytes(16))
  local req = table.concat({
    "GET " .. websocket_path(path) .. " HTTP/1.1",
    "Host: " .. host .. ":" .. port,
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: " .. key,
    "Sec-WebSocket-Version: 13",
    "",  -- empty line = end of headers
    "",
  }, "\r\n")
  tcp:write(req)
  read_http_response(tcp)
end

read_http_response = function(tcp)
  tcp:read_start(function(err, chunk)
    if err then
      Util.log("warn", "HTTP read error: " .. err)
      schedule_reconnect("http: " .. err)
      return
    end
    if not chunk then
      -- Connection closed before we got the response
      schedule_reconnect("connection closed during HTTP upgrade")
      return
    end
    S.frame_buffer = S.frame_buffer .. chunk
    -- Look for end of HTTP response headers
    local hdr_end = S.frame_buffer:find("\r\n\r\n", 1, true)
    if not hdr_end then return end
    local header = S.frame_buffer:sub(1, hdr_end - 1)
    local rest = S.frame_buffer:sub(hdr_end + 4)
    S.frame_buffer = rest
    tcp:read_stop()

    if not header:match("HTTP/1.1 101") and not header:match("HTTP/1.1 101") then
      -- Capture full response for debugging
      local full_resp = header
      schedule_reconnect("expected 101 Switching Protocols; got: " .. full_resp:sub(1, 500))
      return
    end

    -- WebSocket handshake complete. Now we're in framing mode.
    M.set_state("challenged")
    emit("state", M.state())
    -- Begin reading WS frames; the gateway will send connect.challenge next.
    read_ws_frames(tcp)
    if #S.frame_buffer > 0 then
      parse_ws_frames()
    end
  end)
end

read_ws_frames = function(tcp)
  tcp:read_start(function(err, chunk)
    if err then
      Util.log("warn", "WS read error: " .. err)
      schedule_reconnect("ws: " .. err)
      return
    end
    if not chunk then
      Util.log("info", "read_ws_frames: connection closed (chunk nil)")
      on_ws_close()
      return
    end
    S.frame_buffer = S.frame_buffer .. chunk
    parse_ws_frames()
  end)
end

-- Parse complete WS frames from S.frame_buffer. Handles text/binary frames;
-- pings (responds with pong); closes; ignores continuation frames.
parse_ws_frames = function()
  local ok, err = pcall(function()
    _parse_ws_frames_inner()
  end)
  if not ok then
    Util.log("error", "parse_ws_frames crashed: " .. tostring(err))
  end
end

_parse_ws_frames_inner = function()
  while true do
    if #S.frame_buffer < 2 then return end
    local b1 = S.frame_buffer:byte(1)
    local b2 = S.frame_buffer:byte(2)
    local fin = bit.band(bit.rshift(b1, 7), 1)
    local opcode = bit.band(b1, 0x0F)
    local masked = bit.band(bit.rshift(b2, 7), 1)
    local len = bit.band(b2, 0x7F)
    local offset = 3

    if len == 126 then
      if #S.frame_buffer < 4 then return end
      len = bit.bor(bit.lshift(S.frame_buffer:byte(3), 8), S.frame_buffer:byte(4))
      offset = 5
    elseif len == 127 then
      if #S.frame_buffer < 10 then return end
      len = 0  -- treat as oversized
    end

    if masked == 1 then
      if #S.frame_buffer < offset + 4 then return end
      offset = offset + 4
    end

    if #S.frame_buffer < offset + len - 1 then
      return
    end

    local payload = S.frame_buffer:sub(offset, offset + len - 1)
    S.frame_buffer = S.frame_buffer:sub(offset + len)

    if opcode == 0x1 then
      -- text frame
      handle_text_frame(payload)
    elseif opcode == 0x2 then
      -- binary frame
      handle_text_frame(payload)
    elseif opcode == 0x8 then
      -- close
      S.close_code = len >= 2 and (bit.bor(bit.lshift(payload:byte(1), 8), payload:byte(2))) or 0
      S.close_reason = payload:sub(3)
      on_ws_close()
      return
    elseif opcode == 0x9 then
      -- ping: respond with pong
      if S.ws then
        S.ws:write(encode_ws_frame(0xA, payload, true))
      end
    end

    if fin == 0 then
      -- fragmented; not supported in v0.1
    end
  end
end

handle_text_frame = function(payload)
  local ok, frame = pcall(vim.json.decode, payload)
  if not ok or type(frame) ~= "table" then
    Util.log("warn", "could not parse WS text frame: " .. tostring(frame))
    return
  end

  local ftype = frame.type
  if ftype == "event" then
    handle_event(frame)
  elseif ftype == "res" then
    handle_response(frame)
  end
end

handle_event = function(frame)
  local name = frame.event
  local payload = frame.payload or {}

  -- Specific handling
  if name == "connect.challenge" then
    S.nonce = payload.nonce
    S.ts = payload.ts
    M.set_state("handshaking")
    emit("state", M.state())
    emit("connect.challenge", payload)
    send_connect()
  elseif name == "chat" then
    local msg_len = 0
    if type(payload.message) == "table" then
      if type(payload.message.text) == "string" then
        msg_len = #payload.message.text
      elseif type(payload.message.content) == "string" then
        msg_len = #payload.message.content
      elseif type(payload.message.content) == "table" then
        for _, part in ipairs(payload.message.content) do
          if type(part) == "table" and type(part.text) == "string" then
            msg_len = msg_len + #part.text
          elseif type(part) == "string" then
            msg_len = msg_len + #part
          end
        end
      end
    elseif type(payload.content) == "string" then
      msg_len = #payload.content
    elseif type(payload.deltaText) == "string" then
      msg_len = #payload.deltaText
    end
    Util.log("info", string.format("chat event runId=%s session=%s state=%s seq=%s contentLen=%d",
      tostring(payload.runId),
      tostring(payload.sessionKey),
      tostring(payload.state),
      tostring(payload.seq),
      msg_len))

    -- Track ack correlation if this is a chat we sent. Do not match by
    -- sessionKey before ack; stale events from the same session can arrive
    -- while a new send is in flight.
    if payload.runId and S.pending_sends then
      for k, v in pairs(S.pending_sends) do
        if v.runId and v.runId == payload.runId then
          v.ack_received = true
          v.runId = payload.runId
          v.state = payload.state
          if payload.state == "final" or payload.state == "error" then
            S.pending_sends[k] = nil
          end
          break
        end
      end
    end
    emit("chat", payload)
  elseif name == "node.invoke.request" then
    handle_invoke_request(payload)
  else
    -- Generic pass-through
    emit(name, payload)
  end
end

handle_response = function(frame)
  local pending = frame.id and S.pending_requests[frame.id] or nil
  if pending then
    S.pending_requests[frame.id] = nil
    Util.log("info", string.format("response for %s reqId=%s ok=%s latency=%dms",
      pending.method,
      tostring(frame.id),
      tostring(frame.ok),
      Util.now_ms() - pending.sent_at_ms))
  elseif frame.id then
    Util.log("debug", "response for unknown reqId=" .. tostring(frame.id) .. " ok=" .. tostring(frame.ok))
  end

  -- Hello-ok arrives as a response to our connect.
  if frame.ok and frame.payload and frame.payload.type == "hello-ok" then
    local auth = frame.payload.auth or {}
    S.device_token = auth.deviceToken
    S.hello_ok_seen = true
    M.set_state("connected")
    S.reconnect_delay = 1  -- reset backoff
    persist_device_token()
    -- Set up ping timer
    setup_ping_timer()
    emit("state", M.state())
    emit("connect.hello_ok", frame.payload)
    return
  end

  -- Errors. A sessions.send error is a request failure, not a connection
  -- failure; surface it to chat without poisoning connection state.
  if not frame.ok and frame.error then
    Util.log("warn", string.format("res error: code=%s message=%s",
      frame.error.code or "?", frame.error.message or "?"))
    if pending and pending.method == "sessions.send" then
      if pending.idempotency_key then
        S.pending_sends[pending.idempotency_key] = nil
      end
      emit("session.send.failed", {
        idempotency_key = pending.idempotency_key,
        error = frame.error,
      })
      return
    end
    -- For non-send responses, just emit; close handling below will reconnect.
    emit("connect.failed", {
      error = frame.error,
      retryable = frame.error.retryable == true,
    })
  end

  -- Match sessions.send ack by request id. The gateway returns runId in the
  -- response payload, and pending_requests carries the idempotency key that
  -- chat.lua uses to correlate UI state.
  if pending and pending.method == "sessions.send" and frame.ok and frame.payload and frame.payload.runId then
    local idem = pending.idempotency_key
    local send = idem and S.pending_sends[idem] or nil
    if not send then
      Util.log("warn", "sessions.send accepted for missing pending send idem=" .. tostring(idem))
      return
    end
    send.runId = frame.payload.runId
    send.ack_received = true
    Util.log("info", "sessions.send accepted runId=" .. tostring(frame.payload.runId))
    emit("session.send.accepted", {
      idempotency_key = idem,
      runId = frame.payload.runId,
      sessionKey = send.opts and send.opts.key or nil,
    })
  end
end

handle_invoke_request = function(payload)
  -- payload = { id, nodeId, command, paramsJSON, timeoutMs, idempotencyKey }
  local tool = S.tools[payload.command]
  if not tool then
    M.invoke_result({
      id = payload.id,
      ok = false,
      error = { code = "unknown_command", message = "no tool registered for " .. payload.command },
    })
    return
  end

  -- Tier check
  local cfg = Config.current()
  local tier = cfg.tools and cfg.tools.tier or "safe"
  if tool.tier == "privileged" and tier ~= "privileged" then
    M.invoke_result({
      id = payload.id,
      ok = false,
      error = { code = "tier_denied", message = "tool requires privileged tier" },
    })
    return
  end

  -- Decode params
  local params = {}
  if payload.paramsJSON and payload.paramsJSON ~= "" then
    local ok, decoded = pcall(vim.json.decode, payload.paramsJSON)
    if ok then params = decoded end
  end

  -- Run the handler. We do this on the main loop to keep vim API safe.
  -- But vim.schedule_wrap is what we want.
  local invoke_id = payload.id
  local handler = tool.handler
  vim.schedule(function()
    local ok, result = pcall(handler, params)
    if not ok then
      M.invoke_result({
        id = invoke_id,
        ok = false,
        error = { code = "handler_error", message = tostring(result) },
      })
      return
    end
    -- Result should be a table; encode as JSON
    local ok2, result_json = pcall(vim.json.encode, result)
    if not ok2 then
      M.invoke_result({
        id = invoke_id,
        ok = false,
        error = { code = "result_encode_error", message = "could not encode result" },
      })
      return
    end
    M.invoke_result({
      id = invoke_id,
      ok = true,
      payloadJSON = result_json,
    })
  end)

  -- Still emit so chat.lua / other listeners can observe
  emit("node.invoke.request", payload)
end

-- =============================================================================
-- Connect frame (with V3 signing)
-- =============================================================================

send_connect = function()
  -- Defer the entire connect send (including token read and openssl signing)
  -- to the main loop, because vim.fn calls are unsafe in libuv fast events.
  vim.schedule(function()
    -- Decide which auth to send
    local auth
    -- Surface chat sends require operator.write. Use the gateway token for
    -- this local CLI-like surface so a stale node-role deviceToken cannot
    -- cause "unauthorized role: operator" on reconnect.
    auth = { token = read_gateway_token() or "" }
    if not auth.token and not auth.deviceToken then
      Util.log("error", "no auth credentials (gateway token or deviceToken)")
      schedule_reconnect("no auth credentials")
      return
    end

    -- Pick the "signatureToken" — same priority order as the gateway's
    -- resolveSignatureToken: token > deviceToken > bootstrapToken.
    local sig_token = auth.token or auth.deviceToken or auth.bootstrapToken or ""

    local signed_at_ms = Util.epoch_ms()
    local v3_payload = build_v3_payload({
      client_id = "cli",
      client_mode = "cli",
      role = "operator",
      scopes_csv = "operator.read,operator.write",
      signed_at_ms = signed_at_ms,
      token = sig_token,
      nonce = S.nonce,
      platform = "macos",
      device_family = "",
    })
    Util.log("info", "signing V3 connect payload")
    local sig, err = sign_v3_payload(v3_payload)
    if not sig then
      Util.log("error", "V3 signing failed: " .. tostring(err))
      schedule_reconnect("sign: " .. tostring(err))
      return
    end

    local connect_frame = {
      type = "req",
      id = Util.uuid(),
      method = "connect",
      params = {
        minProtocol = 4,
        maxProtocol = 4,
        client = {
          id = "cli",
          displayName = "nvimclaw surface (" .. (vim.fn.hostname() or "unknown") .. ")",
          version = "0.1.6",
          platform = "macos",
          mode = "cli",
        },
        role = "operator",
        scopes = { "operator.read", "operator.write" },
        device = {
          id = S.device_id,
          publicKey = S.public_key_b64url,
          signature = Util.b64url_encode(sig),
          signedAt = signed_at_ms,
          nonce = S.nonce,
        },
        auth = auth,
      },
    }

    Util.log("info", "sending connect (deviceId=" .. S.device_id:sub(1, 12) .. "...)")
    if not S.ws then
      Util.log("error", "S.ws is nil at send time — TCP handle was lost")
      return
    end
    local frame_json = vim.json.encode(connect_frame)
    local frame_bytes = encode_ws_frame(0x1, frame_json, true)
    local ok2, err2 = pcall(function()
      S.ws:write(frame_bytes)
    end)
    if not ok2 then
      schedule_reconnect("connect send: " .. tostring(err2))
    end
  end)
end

-- =============================================================================
-- Frame send (text, masked, opcode 0x1)
-- =============================================================================

encode_ws_frame = function(opcode, payload, masked)
  masked = masked == nil and true or masked
  local use_mask = masked == true or masked == 1
  local len = #payload
  local b1 = bit.bor(0x80, bit.band(opcode, 0x0F))  -- FIN=1, opcode
  local header
  if len < 126 then
    header = string.char(b1, bit.bor(use_mask and 0x80 or 0, len))
  elseif len < 65536 then
    header = string.char(b1, bit.bor(use_mask and 0x80 or 0, 126), math.floor(len / 256), len % 256)
  else
    -- 64-bit length; for our use case we shouldn't hit this
    header = string.char(b1, bit.bor(use_mask and 0x80 or 0, 127))
    for i = 7, 0, -1 do
      header = header .. string.char(math.floor(len / (256 ^ i)) % 256)
    end
  end
  if use_mask then
    local mask = Util.random_bytes(4)
    local masked_payload = {}
    for i = 1, len do
      local b = payload:byte(i)
      masked_payload[i] = string.char(bit.bxor(b, mask:byte(((i - 1) % 4) + 1)))
    end
    return header .. mask .. table.concat(masked_payload)
  end
  return header .. payload
end

send_frame = function(text)
  if not S.ws then
    return false, "no WebSocket handle"
  end
  local bytes = encode_ws_frame(0x1, text, true)
  local ok, err = pcall(function()
    S.ws:write(bytes)
  end)
  if not ok then
    return false, tostring(err)
  end
  return true
end

-- =============================================================================
-- Node-role WebSocket: receives node.invoke.request and replies with results.
-- =============================================================================

local function node_command_names()
  local names = {}
  for name, _ in pairs(S.tools) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

local function node_permissions()
  local permissions = {}
  for name, _ in pairs(S.tools) do
    permissions[name] = true
  end
  return permissions
end

open_node_websocket = function()
  if S.node_ws then
    pcall(function() S.node_ws:close() end)
    S.node_ws = nil
  end
  local cfg = Config.current()
  local host = cfg.gateway.host
  local port = cfg.gateway.port
  local path = cfg.gateway.contextPath
  if type(host) ~= "string" or host == "" or type(port) ~= "number" then
    schedule_node_reconnect("invalid gateway config: host/port missing")
    return
  end

  local tcp = uv.new_tcp()
  if not tcp then
    schedule_node_reconnect("could not create TCP handle")
    return
  end
  S.node_ws = tcp
  S.node_frame_buffer = ""

  tcp:connect(host, port, function(err)
    if err then
      Util.log("warn", "node TCP connect failed: " .. err)
      schedule_node_reconnect("tcp: " .. err)
      return
    end
    send_node_http_upgrade(tcp, host, port, path)
  end)
end

send_node_http_upgrade = function(tcp, host, port, path)
  local key = vim.base64.encode(Util.random_bytes(16))
  local req = table.concat({
    "GET " .. websocket_path(path) .. " HTTP/1.1",
    "Host: " .. host .. ":" .. port,
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: " .. key,
    "Sec-WebSocket-Version: 13",
    "",
    "",
  }, "\r\n")
  tcp:write(req)
  read_node_http_response(tcp)
end

read_node_http_response = function(tcp)
  tcp:read_start(function(err, chunk)
    if err then
      Util.log("warn", "node HTTP read error: " .. err)
      schedule_node_reconnect("http: " .. err)
      return
    end
    if not chunk then
      schedule_node_reconnect("connection closed during node HTTP upgrade")
      return
    end
    S.node_frame_buffer = S.node_frame_buffer .. chunk
    local hdr_end = S.node_frame_buffer:find("\r\n\r\n", 1, true)
    if not hdr_end then return end
    local header = S.node_frame_buffer:sub(1, hdr_end - 1)
    local rest = S.node_frame_buffer:sub(hdr_end + 4)
    S.node_frame_buffer = rest
    tcp:read_stop()

    if not header:match("HTTP/1.1 101") then
      schedule_node_reconnect("expected 101 Switching Protocols; got: " .. header:sub(1, 500))
      return
    end

    S.node_state = "challenged"
    emit("node.state", S.node_state)
    read_node_ws_frames(tcp)
    if #S.node_frame_buffer > 0 then
      parse_node_ws_frames()
    end
  end)
end

read_node_ws_frames = function(tcp)
  tcp:read_start(function(err, chunk)
    if err then
      Util.log("warn", "node WS read error: " .. err)
      schedule_node_reconnect("ws: " .. err)
      return
    end
    if not chunk then
      Util.log("info", "node read_ws_frames: connection closed (chunk nil)")
      on_node_ws_close()
      return
    end
    S.node_frame_buffer = S.node_frame_buffer .. chunk
    parse_node_ws_frames()
  end)
end

parse_node_ws_frames = function()
  local ok, err = pcall(function()
    while true do
      if #S.node_frame_buffer < 2 then return end
      local b1 = S.node_frame_buffer:byte(1)
      local b2 = S.node_frame_buffer:byte(2)
      local fin = bit.band(bit.rshift(b1, 7), 1)
      local opcode = bit.band(b1, 0x0F)
      local masked = bit.band(bit.rshift(b2, 7), 1)
      local len = bit.band(b2, 0x7F)
      local offset = 3

      if len == 126 then
        if #S.node_frame_buffer < 4 then return end
        len = bit.bor(bit.lshift(S.node_frame_buffer:byte(3), 8), S.node_frame_buffer:byte(4))
        offset = 5
      elseif len == 127 then
        if #S.node_frame_buffer < 10 then return end
        len = 0
      end

      if masked == 1 then
        if #S.node_frame_buffer < offset + 4 then return end
        offset = offset + 4
      end

      if #S.node_frame_buffer < offset + len - 1 then
        return
      end

      local payload = S.node_frame_buffer:sub(offset, offset + len - 1)
      S.node_frame_buffer = S.node_frame_buffer:sub(offset + len)

      if opcode == 0x1 or opcode == 0x2 then
        handle_node_text_frame(payload)
      elseif opcode == 0x8 then
        S.node_close_code = len >= 2 and (bit.bor(bit.lshift(payload:byte(1), 8), payload:byte(2))) or 0
        S.node_close_reason = payload:sub(3)
        on_node_ws_close()
        return
      elseif opcode == 0x9 then
        if S.node_ws then
          S.node_ws:write(encode_ws_frame(0xA, payload, true))
        end
      end

      if fin == 0 then
        -- Fragmented frames are not expected for current gateway events.
      end
    end
  end)
  if not ok then
    Util.log("error", "parse_node_ws_frames crashed: " .. tostring(err))
  end
end

handle_node_text_frame = function(payload)
  local ok, frame = pcall(vim.json.decode, payload)
  if not ok or type(frame) ~= "table" then
    Util.log("warn", "could not parse node WS text frame: " .. tostring(frame))
    return
  end

  local ftype = frame.type
  if ftype == "event" then
    handle_node_event(frame)
  elseif ftype == "res" then
    handle_node_response(frame)
  end
end

handle_node_event = function(frame)
  local name = frame.event
  local payload = frame.payload or {}

  if name == "connect.challenge" then
    S.node_nonce = payload.nonce
    S.node_ts = payload.ts
    S.node_state = "handshaking"
    emit("node.state", S.node_state)
    emit("node.connect.challenge", payload)
    send_node_connect()
  elseif name == "node.invoke.request" then
    handle_invoke_request(payload)
  else
    emit(name, payload)
  end
end

handle_node_response = function(frame)
  if frame.ok and frame.payload and frame.payload.type == "hello-ok" then
    local auth = frame.payload.auth or {}
    if auth.deviceToken then
      S.device_token = auth.deviceToken
      persist_device_token()
    end
    S.node_hello_ok_seen = true
    S.node_state = "connected"
    S.node_reconnect_delay = 1
    Util.log("info", "node-role connection ready; commands=" .. table.concat(node_command_names(), ","))
    emit("node.state", S.node_state)
    emit("node.connect.hello_ok", frame.payload)
    return
  end

  if not frame.ok and frame.error then
    Util.log("warn", string.format("node res error: code=%s message=%s",
      frame.error.code or "?",
      frame.error.message or "?"))
    emit("node.connect.failed", {
      error = frame.error,
      retryable = frame.error.retryable == true,
    })
  end
end

send_node_connect = function()
  vim.schedule(function()
    local token = read_gateway_token() or ""
    local auth = {}
    if S.device_token and S.device_token ~= "" then
      auth.deviceToken = S.device_token
    elseif token ~= "" then
      auth.token = token
    end
    if not auth.token and not auth.deviceToken then
      Util.log("error", "node connect has no auth credentials")
      schedule_node_reconnect("no auth credentials")
      return
    end

    local sig_token = auth.token or auth.deviceToken or ""
    local signed_at_ms = Util.epoch_ms()
    local v3_payload = build_v3_payload({
      client_id = "node-host",
      client_mode = "node",
      role = "node",
      scopes_csv = "",
      signed_at_ms = signed_at_ms,
      token = sig_token,
      nonce = S.node_nonce,
      platform = "macos",
      device_family = "",
    })
    Util.log("info", "signing V3 node connect payload")
    local sig, err = sign_v3_payload(v3_payload)
    if not sig then
      Util.log("error", "V3 node signing failed: " .. tostring(err))
      schedule_node_reconnect("node sign: " .. tostring(err))
      return
    end

    local commands = node_command_names()
    local connect_frame = {
      type = "req",
      id = Util.uuid(),
      method = "connect",
      params = {
        minProtocol = 4,
        maxProtocol = 4,
        client = {
          id = "node-host",
          displayName = "nvimclaw node (" .. (vim.fn.hostname() or "unknown") .. ")",
          version = "0.1.6",
          platform = "macos",
          mode = "node",
        },
        role = "node",
        scopes = {},
        caps = { "nvim" },
        commands = commands,
        permissions = node_permissions(),
        device = {
          id = S.device_id,
          publicKey = S.public_key_b64url,
          signature = Util.b64url_encode(sig),
          signedAt = signed_at_ms,
          nonce = S.node_nonce,
        },
        auth = auth,
      },
    }

    Util.log("info", "sending node connect (deviceId=" .. S.device_id:sub(1, 12) .. "..., commands=" .. tostring(#commands) .. ")")
    if not S.node_ws then
      Util.log("error", "S.node_ws is nil at node connect send time")
      return
    end
    local ok2, err2 = pcall(function()
      S.node_ws:write(encode_ws_frame(0x1, vim.json.encode(connect_frame), true))
    end)
    if not ok2 then
      schedule_node_reconnect("node connect send: " .. tostring(err2))
    end
  end)
end

send_node_frame = function(text)
  if not S.node_ws then
    return false, "no node WebSocket handle"
  end
  local bytes = encode_ws_frame(0x1, text, true)
  local ok, err = pcall(function()
    S.node_ws:write(bytes)
  end)
  if not ok then
    return false, tostring(err)
  end
  return true
end

-- =============================================================================
-- Close + reconnect
-- =============================================================================

on_ws_close = function()
  if not S.ws and (M.state() == "disconnected" or M.state() == "reconnecting") then
    return
  end
  if S.ws then
    pcall(function() S.ws:close() end)
    S.ws = nil
  end
  S.frame_buffer = ""
  if S.ping_timer then
    S.ping_timer:stop()
    S.ping_timer:close()
    S.ping_timer = nil
  end
  emit("connect.closed", { code = S.close_code, reason = S.close_reason })
  M.set_state("disconnected")
  emit("state", M.state())
  schedule_reconnect("closed")
end

schedule_reconnect = function(reason)
  if not S.reconnect_enabled then return end
  if M.state() == "reconnecting" then return end  -- already scheduled
  if S.reconnect_timer then return end
  Util.log("info", string.format("reconnect in %ds (%s)", S.reconnect_delay, reason or "unknown"))
  emit("connect.failed", { error = reason, retryable = true })
  M.set_state("reconnecting")
  emit("state", M.state())
  local delay = S.reconnect_delay
  S.reconnect_delay = math.min(S.reconnect_delay * 2, 30)
  local timer = uv.new_timer()
  if not timer then
    Util.log("error", "could not create reconnect timer")
    return
  end
  S.reconnect_timer = timer
  timer:start(delay * 1000, 0, vim.schedule_wrap(function()
    S.reconnect_timer = nil
    timer:stop()
    timer:close()
    M.start()
  end))
end

on_node_ws_close = function()
  if not S.node_ws and (S.node_state == "disconnected" or S.node_state == "reconnecting") then
    return
  end
  if S.node_ws then
    pcall(function() S.node_ws:close() end)
    S.node_ws = nil
  end
  S.node_frame_buffer = ""
  local reason = S.node_close_reason or "closed"
  Util.log("info", string.format("node connection closed code=%s reason=%s",
    tostring(S.node_close_code),
    tostring(reason)))
  S.node_state = "disconnected"
  emit("node.connect.closed", { code = S.node_close_code, reason = reason })
  emit("node.state", S.node_state)
  schedule_node_reconnect("closed")
end

schedule_node_reconnect = function(reason)
  if not S.node_reconnect_enabled then return end
  if S.node_state == "reconnecting" then return end
  if S.node_reconnect_timer then return end
  Util.log("info", string.format("node reconnect in %ds (%s)", S.node_reconnect_delay, reason or "unknown"))
  emit("node.connect.failed", { error = reason, retryable = true })
  S.node_state = "reconnecting"
  emit("node.state", S.node_state)
  local delay = S.node_reconnect_delay
  S.node_reconnect_delay = math.min(S.node_reconnect_delay * 2, 30)
  local timer = uv.new_timer()
  if not timer then
    Util.log("error", "could not create node reconnect timer")
    return
  end
  S.node_reconnect_timer = timer
  timer:start(delay * 1000, 0, vim.schedule_wrap(function()
    S.node_reconnect_timer = nil
    timer:stop()
    timer:close()
    M.start_node()
  end))
end

-- =============================================================================
-- Pings (server tick = 30s; we don't strictly need to send pings, but the
-- server will close idle connections eventually)
-- =============================================================================

setup_ping_timer = function()
  if S.ping_timer then
    pcall(function() S.ping_timer:stop() end)
  end
  S.ping_timer = uv.new_timer()
  if not S.ping_timer then return end
  S.ping_timer:start(25000, 25000, vim.schedule_wrap(function()
    if S.ws then
      pcall(function() S.ws:write(encode_ws_frame(0x9, "", true)) end)
    end
  end))
end

-- =============================================================================
-- Helpers
-- =============================================================================

read_gateway_token = function()
  -- Try env var first
  local env = os.getenv("OPENCLAW_GATEWAY_TOKEN")
  if env and env ~= "" and env ~= "null" and #env >= 20 then
    return env
  end
  -- Otherwise read from ~/.openclaw/openclaw.json
  local path = vim.fn.expand("~/.openclaw/openclaw.json")
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then return nil end
  if data.gateway and data.gateway.auth then
    return data.gateway.auth.token or data.gateway.auth.password
  end
  if data.gateway and data.gateway.remote and data.gateway.remote.auth then
    return data.gateway.remote.auth.token or data.gateway.remote.auth.password
  end
  if data.gateway and data.gateway.remote then
    return data.gateway.remote.token or data.gateway.remote.password
  end
  return nil
end

-- =============================================================================
-- Public diagnostic
-- =============================================================================

function M.info()
  return {
    state = M.state(),
    node_state = S.node_state,
    device_id = S.device_id,
    public_key = S.public_key_b64url,
    gateway_auth_token = read_gateway_token() and "yes" or "no",
    device_token = S.device_token and ("yes (" .. #S.device_token .. " chars)") or "no",
    hello_ok_seen = S.hello_ok_seen,
    node_hello_ok_seen = S.node_hello_ok_seen,
    tools_registered = vim.tbl_count(S.tools),
    pending_sends = vim.tbl_count(S.pending_sends),
    pending_requests = vim.tbl_count(S.pending_requests),
    reconnect_enabled = S.reconnect_enabled,
    close_code = S.close_code,
    close_reason = S.close_reason,
    node_close_code = S.node_close_code,
    node_close_reason = S.node_close_reason,
  }
end

return M
