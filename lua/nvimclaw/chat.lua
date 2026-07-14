--[[
  chat.lua — chat buffer UI.

  This module owns the chat scratch buffer (`nvimclaw://chat`) that lets the
  user talk to an agent session without leaving Neovim.

  Layout (top → bottom in the buffer):

      line 1:    > you: change "hilarius"...        (history, grows upward)
      line 2:    <empty>
      line 3:    < me: :s/hilarius/hilarious/g
      line 4:       done. 3 replacements.
      line 5:    <empty>
      line N:    >                                  (input line — cursor lives here)

  Read-only vs. input:
    * History (everything except the LAST line) is conceptually read-only.
    * The implementation uses a single scratch buffer and leaves normal-mode
      movement alone so the transcript can be navigated with standard keys.

  Public API:
    Chat.open(opts)              — open or focus the chat window
    Chat.close()                 — close the chat window
    Chat.jump_to_input()         — focus the input prompt
    Chat.maybe_open()            — open only if Config.current().attach != "none"
    Chat.send(content)           — send a message through Node.session_send
    Chat.handle_event(name, p)   — internal event dispatcher (called from init.lua)
    Chat.handle_chat_event(p)    — render an incoming chat event into history

  Buffer-local keymaps (registered by _setup_buffer_keymaps):
    <CR>    send the current input line
    gi      jump to input line
    <C-c>   cancel pending send (UI-side; gateway may still process)

  Note: <C-w> is intentionally NOT bound here — we leave Neovim's default
  <C-w> prefix intact so window-local commands (e.g. <C-w>v) keep working.
]]

local M = {}

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------
-- State is per-Neovim-instance, not per-buffer. The chat buffer is a
-- singleton: opening chat twice focuses the existing window.

local state = {
  buf = nil,             -- chat buffer handle
  win = nil,             -- chat window handle
  input_line = nil,      -- 1-based line number of the input line (the LAST line)
  current_idem = nil,    -- idempotency key for the most recent send
  pending_idem = nil,    -- idempotency key of an in-flight session_send (for cancel)
  active_run_id = nil,   -- OpenClaw runId once sessions.send is accepted
  queued_events = {},    -- runId -> { {kind="chat"|"agent", payload=...}, ... }
  active_content = "",   -- latest cumulative assistant snapshot for the active run
  active_seq = nil,      -- highest chat sequence incorporated into active_content
  active_agent_error = nil, -- diagnostic only; chat terminal events remain authoritative
  last_send_ms = nil,    -- when we issued the in-flight send (for latency display)
  connected = false,     -- tracks connect/disconnect for the status line
  status_text = "connecting...",
}

local function parse_input_line(raw)
  raw = raw or ""
  local content = raw:gsub("^%s*>%s?", "")
  -- Older chat buffers used "_" as a fake cursor placeholder. Strip it from
  -- either side so pre-existing prompt lines do not leak underscores into
  -- the user turn.
  content = content:gsub("^_%s*", "")
  content = content:gsub("%s*_%s*$", "")
  return vim.trim(content)
end

local function active_run_matches(payload)
  if not state.active_run_id then
    return false
  end
  if not payload or not payload.runId then
    return false
  end
  return payload.runId == state.active_run_id
end

local function clear_pending()
  state.current_idem = nil
  state.pending_idem = nil
  state.active_run_id = nil
  state.queued_events = {}
  state.active_content = ""
  state.active_seq = nil
  state.active_agent_error = nil
end

local function clear_waiting()
  state.pending_idem = nil
end

local function finish_active_run()
  state.current_idem = nil
  state.pending_idem = nil
  if state.active_run_id then
    state.queued_events[state.active_run_id] = nil
  end
  state.active_run_id = nil
  state.active_content = ""
  state.active_seq = nil
  state.active_agent_error = nil
end

local function status_label(text)
  return "nvimclaw — " .. tostring(text or "")
end

local function statusline_escape(text)
  return tostring(text):gsub("%%", "%%%%")
end

local function apply_window_status()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return
  end
  -- Window-local winbar keeps status visible while the transcript scrolls.
  pcall(vim.api.nvim_set_option_value, "winbar", statusline_escape(status_label(state.status_text)), { win = state.win })
  pcall(vim.api.nvim_set_option_value, "conceallevel", 2, { win = state.win })
end

local function queue_event(kind, payload)
  if not (state.current_idem and payload and payload.runId) then
    return false
  end
  state.queued_events[payload.runId] = state.queued_events[payload.runId] or {}
  table.insert(state.queued_events[payload.runId], { kind = kind, payload = payload })
  return true
end

-- ---------------------------------------------------------------------------
-- Public: open / close / maybe_open
-- ---------------------------------------------------------------------------

--- Open the chat window, or focus it if already open.
-- @param opts table|nil { side = "right"|"left"|"bottom", width = number }
function M.open(opts)
  opts = opts or {}

  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    if M._focus() then
      return
    end
  end

  local Config = require("nvimclaw.config")
  local config = Config.current()

  local setup_needed = not (state.buf and vim.api.nvim_buf_is_valid(state.buf))
  if setup_needed then
    -- Create the scratch buffer (listed = false; scratch = true so :bnext skips it).
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(state.buf, "nvimclaw://chat")
  end

  -- Open a split on the requested side.
  local side = opts.side or config.chat.side or "right"
  local width = opts.width or config.chat.width or 0.4
  if side == "right" then
    vim.cmd("botright vsplit")
  elseif side == "left" then
    vim.cmd("topleft vsplit")
  elseif side == "bottom" then
    vim.cmd("botright split")
  else
    vim.cmd("botright vsplit")
  end

  state.win = vim.api.nvim_get_current_win()
  apply_window_status()

  -- Size the window. For vertical splits, width is a fraction of columns.
  -- For a horizontal "bottom" split, we treat the same number as a fraction
  -- of lines (less common, but keeps the API symmetric).
  if side == "bottom" then
    local rows = math.max(5, math.floor(vim.o.lines * width))
    pcall(vim.api.nvim_win_set_height, state.win, rows)
  else
    local cols = math.max(20, math.floor(vim.o.columns * width))
    pcall(vim.api.nvim_win_set_width, state.win, cols)
  end

  -- Bind the new buffer to our window and finish setup.
  vim.api.nvim_win_set_buf(state.win, state.buf)
  if setup_needed then
    M._setup_buffer()

    -- Render initial state: input prompt only; status is window-local.
    M._render_initial()
    apply_window_status()
  else
    state.input_line = vim.api.nvim_buf_line_count(state.buf)
    apply_window_status()
    pcall(vim.api.nvim_win_set_cursor, state.win, { state.input_line, 2 })
  end
end

--- Close the chat window.
function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
  -- Keep state.buf alive in case the user reopens quickly.
end

--- Open chat only if the configured attach mode is "buffer" or "selection".
-- Called from init.lua's setup() so the chat appears automatically when
-- the user opts into attachment.
function M.maybe_open()
  local Config = require("nvimclaw.config")
  local attach = Config.current().attach
  if attach == "buffer" or attach == "selection" then
    M.open()
  end
end

-- ---------------------------------------------------------------------------
-- Internal: focus an existing chat window
-- ---------------------------------------------------------------------------
function M._focus()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    -- Window gone (user closed it). Try to find a window showing our buffer.
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == state.buf then
        state.win = win
        break
      end
    end
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    apply_window_status()
    -- Snap cursor to the input line.
    if state.input_line then
      pcall(vim.api.nvim_win_set_cursor, state.win, { state.input_line, 2 })
    end
    return true
  end
  return false
end

function M.jump_to_input()
  if not M._focus() then
    M.open()
  end
end

-- ---------------------------------------------------------------------------
-- Internal: buffer setup
-- ---------------------------------------------------------------------------

function M._setup_buffer()
  local b = state.buf

  -- Buffer options: scratch, no swap, no file, no hidden-on-BufLeave wipeout.
  local opts = {
    buftype = "nofile",
    bufhidden = "hide",
    swapfile = false,
    filetype = "markdown",   -- gives us nice comment highlighting on `code`
    wrap = true,
    linebreak = true,
  }
  for k, v in pairs(opts) do
    pcall(vim.api.nvim_buf_set_option, b, k, v)
  end

  -- Buffer-local keymaps.
  M._setup_buffer_keymaps(b)

  -- Do not install cursor-snapping here. The chat transcript should remain
  -- navigable with normal Vim motion keys; <CR> always reads the last line.
end

function M._setup_buffer_keymaps(b)
  -- <CR> in normal mode: send current input line.
  vim.api.nvim_buf_set_keymap(b, "n", "<CR>", "<Cmd>lua require('nvimclaw.chat')._on_send_key()<CR>",
    { noremap = true, silent = true })
  -- <CR> in insert mode: send and stay in insert mode on a fresh input line.
  vim.api.nvim_buf_set_keymap(b, "i", "<CR>", "<ESC><Cmd>lua require('nvimclaw.chat')._on_send_key()<CR>",
    { noremap = true, silent = true })

  -- gi in normal mode: return to the input prompt after browsing history.
  vim.api.nvim_buf_set_keymap(b, "n", "gi", "<Cmd>lua require('nvimclaw.chat').jump_to_input()<CR>",
    { noremap = true, silent = true })

  -- <C-c> in normal and insert: cancel pending send (UI-side).
  vim.api.nvim_buf_set_keymap(b, "n", "<C-c>", "<Cmd>lua require('nvimclaw.chat')._on_cancel_key()<CR>",
    { noremap = true, silent = true })
  vim.api.nvim_buf_set_keymap(b, "i", "<C-c>", "<ESC><Cmd>lua require('nvimclaw.chat')._on_cancel_key()<CR>",
    { noremap = true, silent = true })

  -- Note: <C-w> is intentionally left unbound so Neovim's default <C-w>
  -- window-command prefix (e.g. <C-w>v, <C-w>s) keeps working.
end

-- ---------------------------------------------------------------------------
-- Internal: initial render
-- ---------------------------------------------------------------------------
-- Populates the buffer with the input prompt. Status lives in the window
-- winbar so it remains visible without duplicating inside scrollback.
-- Subsequent history is inserted BEFORE the input line.

function M._render_initial()
  local b = state.buf
  local lines = {
    "> ",                          -- line 1: input prompt
  }
  vim.api.nvim_buf_set_option(b, "modifiable", true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)

  state.input_line = #lines

  -- Place cursor at end of input line (0-based column 2, after "> ").
  pcall(vim.api.nvim_win_set_cursor, state.win, { state.input_line, 2 })
end

-- ---------------------------------------------------------------------------
-- Internal: key handlers
-- ---------------------------------------------------------------------------

--- <CR> handler. Reads the input line, sends it, resets the prompt.
function M._on_send_key()
  local b = state.buf
  if not (b and vim.api.nvim_buf_is_valid(b)) then return end
  if not state.input_line then return end

  -- Input is the LAST line. Pull its contents and strip the "> " prefix.
  local total = vim.api.nvim_buf_line_count(b)
  local lines = vim.api.nvim_buf_get_lines(b, total - 1, total, false)
  local raw = lines[1] or ""
  local content = parse_input_line(raw)
  if content == "" then return end

  M.send(content)
end

--- <C-c> handler. Cancels the UI-side pending state.
-- This does not cancel the gateway-side request. The agent may still process
-- and respond; we just stop waiting locally.
function M._on_cancel_key()
  if state.current_idem then
    clear_pending()
    M._set_status("cancelled (gateway may still process)")
  end
end

-- ---------------------------------------------------------------------------
-- Public: send
-- ---------------------------------------------------------------------------

--- Send a message through the Node.
-- Renders the user's turn into history, then clears the input line, then
-- calls Node.session_send. The matching chat event arrives later via
-- handle_chat_event and is rendered into history by that path.
-- @param content string the user message
function M.send(content)
  if content == nil or content == "" then return end
  if state.current_idem then
    M._set_status("waiting for current response")
    return false, "pending response"
  end
  local Config = require("nvimclaw.config")
  local Util = require("nvimclaw.util")
  local Node = require("nvimclaw.node")

  local config = Config.current()
  local idem = Util.uuid()
  state.current_idem = idem
  state.pending_idem = idem
  state.active_run_id = nil
  state.queued_events = {}
  state.active_content = ""
  state.active_seq = nil
  state.active_agent_error = nil
  state.last_send_ms = Util.now_ms()

  -- Render the user's turn into history (above the input line).
  M._append_history({ "", "> " .. content, "" })

  -- Reset the input line.
  M._reset_input_line()

  -- Status line: show "sending..." with elapsed time.
  M._set_status("sending...")

  -- Hand off to the Node. We don't try to render the response here; the
  -- chat event will arrive via Node.on_event and route through
  -- Chat.handle_event → Chat.handle_chat_event.
  local ok, result, err = pcall(Node.session_send, {
    key = config.session,
    content = content,
    idempotency_key = idem,
    timeout_ms = config.receive_timeout_ms,
  })
  if not ok or not result then
    clear_pending()
    M._set_status("send failed: " .. tostring(ok and err or result))
    return false, tostring(ok and err or result)
  end

  vim.defer_fn(function()
    if state.pending_idem == idem then
      clear_waiting()
      M._set_status("connected (response still pending upstream)")
    end
  end, (config.receive_timeout_ms or 15000) + 1000)
  return true
end

-- ---------------------------------------------------------------------------
-- Internal: buffer mutation helpers
-- ---------------------------------------------------------------------------

--- Insert lines before the input line (so they appear in history).
function M._append_history(new_lines)
  local b = state.buf
  if not (b and vim.api.nvim_buf_is_valid(b)) then return end
  if not state.input_line then return end

  vim.api.nvim_buf_set_option(b, "modifiable", true)

  -- The input is always the LAST line. We need to splice new lines in
  -- before it. nvim_buf_set_lines with start = (input_line - 1), end = (input_line - 1)
  -- inserts WITHOUT replacing the input line.
  local total = vim.api.nvim_buf_line_count(b)
  -- Insertion point is the line just before the input line.
  local insert_at = total - 1

  -- Build the splice: new_lines + current input line.
  local current_input = vim.api.nvim_buf_get_lines(b, insert_at, total, false)
  local splice = {}
  for _, ln in ipairs(new_lines) do table.insert(splice, ln) end
  for _, ln in ipairs(current_input) do table.insert(splice, ln) end

  vim.api.nvim_buf_set_lines(b, insert_at, total, false, splice)

  -- Recompute input_line (it's now the new last line).
  state.input_line = vim.api.nvim_buf_line_count(b)

  -- Snap cursor back to the input line.
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_set_cursor, state.win, { state.input_line, 2 })
  end
end

--- Reset the input line to "> " with cursor at the prompt position.
function M._reset_input_line()
  local b = state.buf
  if not (b and vim.api.nvim_buf_is_valid(b)) then return end

  vim.api.nvim_buf_set_option(b, "modifiable", true)
  local total = vim.api.nvim_buf_line_count(b)
  vim.api.nvim_buf_set_lines(b, total - 1, total, false, { "> " })
  state.input_line = total

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_set_cursor, state.win, { state.input_line, 2 })
  end
end

local function remove_legacy_status_line(b)
  local function is_legacy_separator(line)
    return type(line) == "string" and line:find("─", 1, true) == 1
  end

  local first = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
  if first and first:match("^nvimclaw%s") then
    vim.api.nvim_buf_set_lines(b, 0, 1, false, {})
    local prefix = vim.api.nvim_buf_get_lines(b, 0, 2, false)
    if is_legacy_separator(prefix[1]) and prefix[2] == "" then
      vim.api.nvim_buf_set_lines(b, 0, 2, false, {})
    elseif is_legacy_separator(prefix[1]) then
      vim.api.nvim_buf_set_lines(b, 0, 1, false, {})
    end
  end

  local total = vim.api.nvim_buf_line_count(b)
  local last = vim.api.nvim_buf_get_lines(b, total - 1, total, false)[1]
  if last == "> _" then
    vim.api.nvim_buf_set_lines(b, total - 1, total, false, { "> " })
  end
  state.input_line = vim.api.nvim_buf_line_count(b)
end

--- Update the visible window status with current state.
function M._set_status(text)
  state.status_text = tostring(text)
  -- vim API calls are unsafe in libuv fast event contexts. Defer to the
  -- main loop. The cost is a one-tick latency on status updates, which is
  -- imperceptible.
  vim.schedule(function()
    local b = state.buf
    if not (b and vim.api.nvim_buf_is_valid(b)) then return end

    vim.api.nvim_buf_set_option(b, "modifiable", true)
    remove_legacy_status_line(b)
    apply_window_status()
  end)
end

-- ---------------------------------------------------------------------------
-- Public: event dispatch
-- ---------------------------------------------------------------------------

--- Generic event dispatcher — called by init.lua's Node.on_event wiring.
-- Routes events to the right internal handler.
-- @param event_name string e.g. "chat", "connect.hello_ok", "connect.closed"
-- @param payload table|nil event-specific data
function M.handle_event(event_name, payload)
  if event_name == "chat" then
    M.handle_chat_event(payload)
  elseif event_name == "session.send.accepted" then
    M.handle_send_accepted(payload)
  elseif event_name == "session.send.failed" then
    M.handle_send_failed(payload)
  elseif event_name == "agent" then
    M.handle_agent_event(payload)
  elseif event_name == "connect.hello_ok" then
    state.connected = true
    M._set_status("connected")
  elseif event_name == "connect.closed" or event_name == "connect.failed" then
    state.connected = false
    clear_pending()
    local reason = (payload and (payload.reason or payload.error)) or "closed"
    M._set_status("disconnected (" .. tostring(reason) .. ")")
  elseif event_name == "connect.challenge" then
    M._set_status("authenticating...")
  elseif event_name == "connect.connecting" or event_name == "connecting" then
    M._set_status("connecting...")
  end
end

function M.handle_send_accepted(payload)
  if not (payload and state.current_idem and payload.idempotency_key == state.current_idem) then
    return
  end
  state.active_run_id = payload.runId
  state.active_content = ""
  state.active_seq = nil
  state.active_agent_error = nil
  M._set_status("thinking...")
  local queued = state.queued_events[payload.runId]
  state.queued_events[payload.runId] = nil
  if queued then
    for _, item in ipairs(queued) do
      if item.kind == "chat" then
        M.handle_chat_event(item.payload)
      elseif item.kind == "agent" then
        M.handle_agent_event(item.payload)
      end
    end
  end
end

function M.handle_send_failed(payload)
  if not (payload and state.current_idem and payload.idempotency_key == state.current_idem) then
    return
  end
  local err = payload.error
  local message = type(err) == "table" and (err.message or err.code) or err
  clear_pending()
  M._set_status("send failed")
  M._append_history({ "", "! send failed: " .. tostring(message or "gateway error"), "" })
end

function M.handle_agent_event(payload)
  if type(payload) ~= "table" then return end
  if not active_run_matches(payload) then
    queue_event("agent", payload)
    return
  end
  local data = payload.data
  if type(data) ~= "table" then return end
  local err = data.error or data.errorMessage or data.rawErrorPreview
  if err then
    -- Agent-stream diagnostics can race with the authoritative chat terminal
    -- event. Keep the diagnostic as a fallback, but do not finish the run or
    -- discard a chat snapshot that may already be in flight.
    state.active_agent_error = type(err) == "table" and (err.message or err.code) or tostring(err)
    M._set_status("agent error reported (waiting for chat result)")
  end
end

local function message_text(message)
  if type(message) == "string" then return message end
  if type(message) ~= "table" then return nil end
  if type(message.text) == "string" then return message.text end
  if type(message.content) == "string" then return message.content end
  if type(message.content) ~= "table" then return nil end

  local parts = {}
  for _, part in ipairs(message.content) do
    if type(part) == "table" and type(part.text) == "string" then
      table.insert(parts, part.text)
    elseif type(part) == "string" then
      table.insert(parts, part)
    end
  end
  return table.concat(parts, "\n")
end

local function update_active_content(payload)
  local seq = tonumber(payload.seq)
  if seq and state.active_seq and seq < state.active_seq then
    return state.active_content
  end

  local snapshot = message_text(payload.message)
  if snapshot == nil and type(payload.content) == "string" then
    snapshot = payload.content
  end

  if snapshot ~= nil then
    -- Some gateways emit an empty message on the terminal frame. Preserve the
    -- last non-empty snapshot received on a delta in that case.
    if snapshot ~= "" or state.active_content == "" then
      state.active_content = snapshot
    end
  elseif type(payload.deltaText) == "string" then
    if payload.replace == true then
      state.active_content = payload.deltaText
    elseif payload.deltaText:sub(1, #state.active_content) == state.active_content then
      -- Be tolerant of older gateways that put a cumulative snapshot in
      -- deltaText even though protocol v4 defines it as an increment.
      state.active_content = payload.deltaText
    else
      state.active_content = state.active_content .. payload.deltaText
    end
  end

  if seq then
    state.active_seq = math.max(state.active_seq or seq, seq)
  end
  return state.active_content
end

--- Render a chat event into the history area.
-- Light markdown: backticks for inline code are rendered as-is (the
-- buffer's filetype=markdown does the rest). Blank lines between turns
-- keep individual turns visually separate.
-- @param payload table { runId, sessionKey, seq, state, message, errorMessage }
function M.handle_chat_event(payload)
  if not payload then return end
  if not active_run_matches(payload) then
    queue_event("chat", payload)
    return
  end

  -- Protocol v4 carries the latest cumulative message snapshot on deltas and
  -- finals. Retain it so an empty/error terminal frame cannot erase text the
  -- user already received upstream.
  local content = update_active_content(payload)

  local ev_state = payload.state or "final"
  if ev_state == "delta" then
    if active_run_matches(payload) then
      M._set_status("receiving...")
    end
    return
  elseif ev_state == "started" or ev_state == "in_progress" then
    if active_run_matches(payload) then
      M._set_status("thinking...")
    end
    return
  end

  -- Build the rendered block.
  local lines = { "" }   -- leading blank for visual separation
  if ev_state == "error" then
    if content ~= "" then
      table.insert(lines, "< me:")
      for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, "  " .. line)
      end
    end
    local err = payload.errorMessage or payload.error or state.active_agent_error or "gateway error"
    if type(err) == "table" then err = err.message or err.code or vim.inspect(err) end
    table.insert(lines, "! " .. tostring(err))
  elseif ev_state == "aborted" then
    table.insert(lines, "! response aborted")
    if content ~= "" then
      for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, "  " .. line)
      end
    end
  else
    -- Default: full assistant turn.
    table.insert(lines, "< me:")
    -- Split content into lines so it renders as multi-line in the buffer.
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, "  " .. line)
    end
  end
  table.insert(lines, "")  -- trailing blank

  M._append_history(lines)

  -- If this chat event matches our pending send, clear pending + update
  -- status with elapsed time.
  if active_run_matches(payload) then
    local Util = require("nvimclaw.util")
    local elapsed = state.last_send_ms and (Util.now_ms() - state.last_send_ms) or nil
    finish_active_run()
    if ev_state == "aborted" then
      M._set_status("connected (aborted)")
    elseif elapsed then
      M._set_status(string.format("connected (last round-trip %d ms)", elapsed))
    else
      M._set_status("connected")
    end
  end
end

-- ---------------------------------------------------------------------------
-- Module export
-- ---------------------------------------------------------------------------

return M
