local root = vim.fn.getcwd()
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local function fail(message)
  error(message, 2)
end

local function assert_true(value, message)
  if not value then
    fail(message or "assertion failed")
  end
end

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    fail(string.format("%s: expected %s, got %s", message or "assert_equal failed", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function realpath(path)
  return vim.loop.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")
end

local function writefile(path, lines)
  vim.fn.writefile(lines, path)
end

local function main()
local Config = require("nvimclaw.config")
local Tools = require("nvimclaw.tools")

local parsed_gateway = Config._parse_gateway_url("ws://127.0.0.1:18789/openclaw")
assert_true(parsed_gateway ~= nil, "remote gateway url parsed")
assert_equal(parsed_gateway.host, "127.0.0.1", "remote gateway host")
assert_equal(parsed_gateway.port, 18789, "remote gateway port")
assert_equal(parsed_gateway.contextPath, "/openclaw", "remote gateway path")
assert_equal(Config._parse_gateway_url("wss://gateway.example.com"), nil, "wss currently unsupported")

Config.reset()
Config.apply({ gateway = "ws://127.0.0.1:18789" })
assert_equal(Config.current().gateway.host, "127.0.0.1", "string gateway url host")
assert_equal(Config.current().gateway.port, 18789, "string gateway url port")

Config.reset()
Config.apply({ gateway = { url = "ws://127.0.0.1:18789/openclaw" } })
assert_equal(Config.current().gateway.host, "127.0.0.1", "gateway.url host")
assert_equal(Config.current().gateway.contextPath, "/openclaw", "gateway.url path")

Config.reset()
Config.apply({ gateway = { remote = { url = "ws://127.0.0.1:18789" } } })
assert_equal(Config.current().gateway.host, "127.0.0.1", "gateway.remote.url host")
assert_equal(Config.current().gateway.port, 18789, "gateway.remote.url port")

Config.reset()
Config.apply({ gateway = { remote = "ws://127.0.0.1:18789" } })
assert_equal(Config.current().gateway.host, "127.0.0.1", "gateway.remote string host")
assert_equal(Config.current().gateway.port, 18789, "gateway.remote string port")

Config.reset()
Config.apply({ gateway = { url = "127.0.0.1:18789" } })
assert_equal(Config.current().gateway.host, "127.0.0.1", "bare gateway.url host")
assert_equal(Config.current().gateway.port, 18789, "bare gateway.url port")

local registered = {}
local dummy_node = {
  register_tool = function(tool)
    registered[tool.name] = tool
  end,
}

Config.reset()
Config.apply({
  workspace_root = tmp,
  tools = { tier = "safe" },
})
Tools.register_all(dummy_node)

assert_true(registered["nvim.buffer.current"] ~= nil, "buffer.current registered")
assert_true(registered["nvim.buffer.list"] ~= nil, "buffer.list registered")
assert_true(registered["nvim.ex.substitute"] ~= nil, "ex.substitute registered")
local described = Tools._tool_describe({})
assert_equal(described.result.plugin_version, "0.1.6", "describe plugin version")
local described_buffer_list = false
for _, name in ipairs(described.result.tools.safe) do
  if name == "nvim.buffer.list" then described_buffer_list = true end
end
assert_true(described_buffer_list, "describe advertises buffer.list as safe")

vim.cmd("enew")
local empty_unnamed_buf = vim.api.nvim_get_current_buf()
require("nvimclaw.chat").open({ side = "right", width = 0.4 })
local empty_unnamed_current = Tools._tool_buffer_current({ include_content = true })
assert_true(empty_unnamed_current.ok, "empty unnamed visible buffer current ok")
assert_equal(empty_unnamed_current.result.buffer_id, empty_unnamed_buf, "chat focus targets empty unnamed visible buffer")
assert_equal(empty_unnamed_current.result.path, "", "empty unnamed visible buffer path is empty")
assert_equal(empty_unnamed_current.result.target_source, "last_file_buffer", "empty unnamed target source")
local listed = Tools._invoke("buffer.list", {})
assert_true(listed.ok, "buffer.list available in safe tier")
local listed_empty_unnamed = false
for _, item in ipairs(listed.result.buffers) do
  if item.buffer_id == empty_unnamed_buf then
    listed_empty_unnamed = item.path == "" and item.visible == true
  end
end
assert_true(listed_empty_unnamed, "buffer.list discovers visible unnamed buffer by id")
require("nvimclaw.chat").close()

local doc = tmp .. "/doc.md"
local doc_rel = "doc.md"
writefile(doc, {
  "Schopenhauer is hilarius.",
  "Second line.",
  "Third line.",
})

vim.cmd("edit " .. vim.fn.fnameescape(doc))
Tools.note_current_buffer()
local file_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(0, { 2, 3 })

require("nvimclaw.chat").open({ side = "right", width = 0.4 })
local current = Tools._tool_buffer_current({ include_content = true, max_lines = 2 })
assert_true(current.ok, "buffer.current ok")
assert_equal(realpath(current.result.path), realpath(doc), "chat focus targets last file buffer")
assert_equal(current.result.target_source, "last_file_buffer", "target source")
assert_equal(current.result.lines[1], "Schopenhauer is hilarius.", "current content")

local read = Tools._tool_buffer_read({})
assert_true(read.ok, "buffer.read without path ok")
assert_equal(realpath(read.result.path), realpath(doc), "buffer.read without path targets last file buffer")

local cursor = Tools._tool_cursor_get({})
assert_true(cursor.ok, "cursor.get without path ok")
assert_equal(cursor.result.buffer_id, file_buf, "cursor.get without path targets last file buffer")
assert_equal(cursor.result.line, 2, "cursor line follows file window")

require("nvimclaw.chat").close()
local Init = require("nvimclaw")
Init._register_target_buffer_autocmd()
local code_path = tmp .. "/test.txt"
writefile(code_path, {
  "10 PRINT \"APPLE\"",
  "20 GOTO 10",
})
vim.cmd("edit " .. vim.fn.fnameescape(code_path))
local code_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(code_buf, 0, 1, false, { "10 PRINT \"ORANGE\"" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = code_buf })
require("nvimclaw.chat").open({ side = "right", width = 0.4 })
local edited_current = Tools._tool_buffer_current({ include_content = true, max_lines = 1 })
assert_true(edited_current.ok, "edited buffer target current ok")
assert_equal(edited_current.result.buffer_id, code_buf, "chat focus targets most recently edited file buffer")
assert_equal(edited_current.result.lines[1], "10 PRINT \"ORANGE\"", "edited buffer content returned")

local denied = Tools._invoke("buffer.replace_lines", {
  path = doc_rel,
  start = 0,
  ["end"] = 1,
  lines = { "Replacement" },
})
assert_true(not denied.ok, "privileged tool denied in safe tier")
assert_equal(denied.error.code, "tier_denied", "tier denied code")

local unknown = Tools._invoke("buffer.read", { path = doc_rel, extra = true })
assert_true(not unknown.ok, "unknown param rejected")
assert_equal(unknown.error.code, "unknown_param", "unknown param code")

Config.apply({
  workspace_root = tmp,
  tools = { tier = "privileged" },
})

local missing_open_path = Tools._invoke("buffer.open", {})
assert_true(not missing_open_path.ok, "buffer.open requires path")
assert_equal(missing_open_path.error.code, "unknown_param", "missing buffer.open path error")
assert_equal(missing_open_path.error.param, "path", "missing buffer.open path parameter")

local stale = Tools._invoke("buffer.replace_lines", {
  path = doc_rel,
  start = 1,
  ["end"] = 2,
  lines = { "Changed line." },
  expected_changedtick = -1,
})
assert_true(not stale.ok, "stale changedtick conflicts")
assert_equal(stale.error.code, "conflict", "conflict code")

local tick = vim.api.nvim_buf_get_changedtick(file_buf)
local before = vim.api.nvim_buf_get_lines(file_buf, 1, 2, false)
local replaced = Tools._invoke("buffer.replace_lines", {
  path = doc_rel,
  start = 1,
  ["end"] = 2,
  lines = { "Changed line." },
  expected_changedtick = tick,
  expected_line_hash = Tools._hash_lines(before),
})
assert_true(replaced.ok, "replace_lines applies with matching guards")
assert_equal(vim.api.nvim_buf_get_lines(file_buf, 1, 2, false)[1], "Changed line.", "line replaced")

local dry = Tools._invoke("ex.substitute", {
  path = doc_rel,
  pattern = "hilarius",
  replacement = "hilarious",
  flags = "g",
  dry_run = true,
})
assert_true(dry.ok, "substitute dry run ok")
assert_equal(dry.result.matches, 1, "substitute dry run match count")

local sub_tick = vim.api.nvim_buf_get_changedtick(file_buf)
local sub = Tools._invoke("ex.substitute", {
  path = doc_rel,
  pattern = "hilarius",
  replacement = "hilarious",
  flags = "g",
  expected_changedtick = sub_tick,
  expected_line_hash = dry.result.line_hash,
})
assert_true(sub.ok, "substitute apply ok")
assert_equal(sub.result.replaced, 1, "substitute replaced count")
assert_equal(vim.api.nvim_buf_get_lines(file_buf, 0, 1, false)[1], "Schopenhauer is hilarious.", "substitute updated buffer")

vim.cmd("enew")
local scratch_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(scratch_buf, 0, -1, false, { "aoeuli" })
Tools.note_current_buffer()
require("nvimclaw.chat").open({ side = "right", width = 0.4 })

local scratch_current = Tools._tool_buffer_current({ include_content = true })
assert_true(scratch_current.ok, "unnamed buffer current ok")
assert_equal(scratch_current.result.buffer_id, scratch_buf, "chat focus targets unnamed buffer")
assert_equal(scratch_current.result.path, "", "unnamed buffer has empty path")
assert_equal(scratch_current.result.content, "aoeuli", "unnamed buffer content")

local scratch_read = Tools._tool_buffer_read({})
assert_true(scratch_read.ok, "unnamed default read ok")
assert_equal(scratch_read.result.buffer_id, scratch_buf, "unnamed read returns buffer id")
assert_equal(scratch_read.result.content, "aoeuli", "unnamed read content")

local scratch_write = Tools._invoke("buffer.write", {
  buffer_id = scratch_buf,
  content = "aoeuli-was-here",
  expected_changedtick = vim.api.nvim_buf_get_changedtick(scratch_buf),
})
assert_true(scratch_write.ok, "buffer.write by buffer_id ok")
assert_equal(vim.api.nvim_buf_get_lines(scratch_buf, 0, 1, false)[1], "aoeuli-was-here", "buffer_id write updated unnamed buffer")

local scratch_dry = Tools._invoke("ex.substitute", {
  buffer_id = scratch_buf,
  pattern = "was",
  replacement = "is",
  flags = "",
  dry_run = true,
})
assert_true(scratch_dry.ok, "substitute by buffer_id dry run ok")

local scratch_sub = Tools._invoke("ex.substitute", {
  buffer_id = scratch_buf,
  pattern = "was",
  replacement = "is",
  flags = "",
  expected_changedtick = vim.api.nvim_buf_get_changedtick(scratch_buf),
  expected_line_hash = scratch_dry.result.line_hash,
})
assert_true(scratch_sub.ok, "substitute by buffer_id apply ok")
assert_equal(vim.api.nvim_buf_get_lines(scratch_buf, 0, 1, false)[1], "aoeuli-is-here", "buffer_id substitute updated unnamed buffer")

local scratch_count = vim.api.nvim_buf_line_count(scratch_buf)
local scratch_append = Tools._invoke("buffer.replace_lines", {
  buffer_id = scratch_buf,
  start = scratch_count,
  ["end"] = scratch_count,
  lines = { "", "A new paragraph appended by the agent." },
  expected_changedtick = vim.api.nvim_buf_get_changedtick(scratch_buf),
})
assert_true(scratch_append.ok, "append paragraph by buffer_id ok")
assert_equal(vim.api.nvim_buf_get_lines(scratch_buf, scratch_count + 1, scratch_count + 2, false)[1], "A new paragraph appended by the agent.", "paragraph appended to unnamed buffer")

local layout_before = {}
for _, win in ipairs(vim.api.nvim_list_wins()) do
  layout_before[win] = vim.api.nvim_win_get_buf(win)
end
local broad_ex = Tools._invoke("ex.command", {
  cmd = "bufdo 1s/aoeuli-is-here/aoeuli-stayed-visible/e",
})
assert_true(broad_ex.ok, "broad ex command ok")
for win, buf in pairs(layout_before) do
  assert_true(vim.api.nvim_win_is_valid(win), "window still valid after broad ex command")
  assert_equal(vim.api.nvim_win_get_buf(win), buf, "ex.command preserved window buffers")
end

local outside = Tools._invoke("buffer.read", { path = root .. "/README.md" })
assert_true(not outside.ok, "path outside workspace denied")
assert_equal(outside.error.code, "path_denied", "path denied code")

-- Chat protocol-v4 regression coverage. Delta events can contain the only
-- usable assistant snapshot when a terminal frame is empty or reports an
-- error, so exercise the public event handlers against the real chat buffer.
local Chat = require("nvimclaw.chat")
local Node = require("nvimclaw.node")
local original_session_send = Node.session_send
local sent_opts = nil
Node.session_send = function(opts)
  sent_opts = opts
  return { idempotency_key = opts.idempotency_key }
end

local function chat_text()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == "nvimclaw://chat" then
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
  end
  return ""
end

local function begin_chat_run(run_id)
  sent_opts = nil
  local ok = Chat.send("protocol regression " .. run_id)
  assert_true(ok, "chat send starts " .. run_id)
  assert_true(sent_opts and sent_opts.idempotency_key, "chat send captures idempotency key")
  Chat.handle_send_accepted({
    idempotency_key = sent_opts.idempotency_key,
    runId = run_id,
  })
end

Chat.open({ side = "right", width = 0.4 })

begin_chat_run("empty-final")
Chat.handle_chat_event({
  runId = "empty-final",
  state = "delta",
  seq = 1,
  message = { content = { { type = "text", text = "complete answer from delta" } } },
})
Chat.handle_chat_event({
  runId = "empty-final",
  state = "final",
  seq = 2,
  message = { content = {} },
})
assert_true(chat_text():find("complete answer from delta", 1, true) ~= nil, "empty final preserves delta snapshot")

begin_chat_run("error-with-content")
Chat.handle_chat_event({ runId = "error-with-content", state = "delta", seq = 1, deltaText = "partial " })
Chat.handle_chat_event({ runId = "error-with-content", state = "delta", seq = 2, deltaText = "answer before error" })
Chat.handle_chat_event({ runId = "error-with-content", state = "error", seq = 3, errorMessage = "fail" })
local error_text = chat_text()
assert_true(error_text:find("partial answer before error", 1, true) ~= nil, "error preserves accumulated response")
assert_true(error_text:find("! fail", 1, true) ~= nil, "error remains visible after response")

begin_chat_run("late-error")
Chat.handle_chat_event({
  runId = "late-error",
  state = "final",
  seq = 10,
  message = { text = "successful final survives" },
})
local before_late_error = chat_text()
Chat.handle_chat_event({ runId = "late-error", state = "error", seq = 1, errorMessage = "late fail" })
assert_equal(chat_text(), before_late_error, "late error after final is ignored")

begin_chat_run("agent-error-race")
Chat.handle_chat_event({
  runId = "agent-error-race",
  state = "delta",
  seq = 4,
  message = { text = "answer survives agent diagnostic" },
})
Chat.handle_agent_event({ runId = "agent-error-race", data = { error = "transient fail" } })
Chat.handle_chat_event({ runId = "agent-error-race", state = "final", seq = 5, message = { text = "" } })
assert_true(chat_text():find("answer survives agent diagnostic", 1, true) ~= nil, "agent diagnostic does not finish chat run")

Node.session_send = original_session_send
Chat.close()

print("nvimclaw headless tests passed")
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  io.stderr:write(tostring(err) .. "\n")
  vim.cmd("cquit")
end
vim.cmd("qa!")
