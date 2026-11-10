local M = {}
local uv = vim.uv or vim.loop
local source = debug.getinfo(1, "S").source:sub(2)
local script = vim.fn.fnamemodify(source, ":p:h:h:h") .. "/shell/completion.zsh"
local state = { generation = 0, sequence = 0, history = {}, session_history = {}, history_version = 0 }
local dispatch

local function read(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local data = file:read("*a")
  file:close()
  return data
end

local function write(path, data)
  local file, err = io.open(path, "wb")
  if not file then
    return nil, err
  end
  local ok = file:write(data)
  file:close()
  return ok
end

local function fields(data)
  local result = {}
  for value in (data or ""):gmatch("([^%z]*)%z") do
    result[#result + 1] = value
  end
  return result
end

local function cleanup()
  if state.directory then
    vim.fn.delete(state.directory, "rf")
    state.directory = nil
  end
end

function M.stop(reason)
  state.last_error = reason
  state.generation = state.generation + 1
  local job, pending, queued = state.job, state.pending, state.queued
  state.job, state.pending, state.queued = nil, nil, nil
  state.ready = false
  if job then
    pcall(vim.fn.jobstop, job)
  end
  cleanup()
  if pending then
    pending.callback(nil, reason or "zsh stopped")
  end
  if queued then
    queued.callback(nil, reason or "zsh stopped")
  end
end

local function finish(id)
  if not state.pending or state.pending.id ~= id then
    return
  end
  local pending = state.pending
  state.pending = nil
  local parts = fields(read(state.directory .. "/response"))
  local items, seen = {}, {}
  for i = 1, #parts - 1, 2 do
    local line = parts[i] .. parts[i + 1]
    if not seen[line] and not line:find("[\r\n]") then
      seen[line] = true
      items[#items + 1] = { text = line, cursor = #parts[i], source = "zsh" }
    end
  end
  pending.callback(items)
  dispatch()
end

local function start()
  if state.job then
    return true
  end
  if vim.fn.executable(state.config.shell) ~= 1 then
    return false, "zsh executable not found"
  end
  state.directory = vim.fn.tempname() .. "-suggestions"
  vim.fn.mkdir(state.directory, "p", 448) -- 0700: shell history stays private.
  state.output, state.ready = "", false
  local generation = state.generation
  local job = vim.fn.jobstart({ state.config.shell, "-i", script }, {
    pty = true,
    width = 160,
    height = 24,
    env = vim.tbl_extend("force", state.config.env or {}, {
      SUGGESTIONS_DIRECTORY = state.directory,
      SUGGESTIONS_LIMIT = tostring(state.config.max_results),
      SUGGESTIONS_HISTORY = state.config.history_file or "",
      SUGGESTIONS_HISTORY_LIMIT = tostring(state.config.history_limit),
      TERM = "xterm-256color",
    }),
    on_stdout = function(_, data)
      if generation ~= state.generation then
        return
      end
      state.output = state.output .. table.concat(data, "\n")
      while true do
        local first, last, marker = state.output:find("SUGGESTIONS:([%w]+)\r?\n")
        if not first then
          break
        end
        state.output = state.output:sub(last + 1)
        if marker == "READY" then
          state.ready = true
          state.last_error = nil
          state.history =
            vim.list_extend(vim.deepcopy(state.session_history), fields(read(state.directory .. "/history")))
          state.history_version = state.history_version + 1
          dispatch()
        else
          finish(tonumber(marker))
        end
      end
      -- Ignore prompt/theme chatter; the protocol is carried in files.
      if #state.output > 8192 then
        state.output = state.output:sub(-1024)
      end
    end,
    on_exit = function(_, code)
      if generation == state.generation then
        M.stop("zsh exited (" .. code .. ")")
      end
    end,
  })
  if job <= 0 then
    cleanup()
    return false, "could not start zsh"
  end
  state.job = job
  vim.defer_fn(function()
    if generation == state.generation and not state.ready then
      M.stop("zsh startup timed out")
    end
  end, state.config.startup_timeout_ms)
  return true
end

dispatch = function()
  if not state.ready or state.pending or not state.queued then
    return
  end
  local request = state.queued
  state.queued = nil
  if request.history_limit then
    request.callback(M.history("", request.history_limit))
    return
  end
  state.sequence = state.sequence + 1
  request.id = state.sequence
  local data = table.concat(
    { tostring(request.id), request.cwd, request.text, tostring(vim.fn.strchars(request.text:sub(1, request.cursor))) },
    "\0"
  ) .. "\0"
  local ok, err = write(state.directory .. "/request", data)
  if not ok then
    request.callback(nil, err)
    return
  end
  state.pending = request
  vim.api.nvim_chan_send(state.job, "\27[99~")
  local generation = state.generation
  vim.defer_fn(function()
    if generation == state.generation and state.pending == request then
      M.stop("zsh completion timed out")
    end
  end, state.config.timeout_ms)
end

function M.setup(config)
  M.stop()
  state.config = config
  state.history, state.session_history = {}, {}
  state.history_version = state.history_version + 1
end

function M.reload()
  M.stop("zsh reloaded")
  state.history = vim.deepcopy(state.session_history)
  state.history_version = state.history_version + 1
  local ok, err = start()
  state.last_error = err
  return ok, err
end

local function enqueue(request)
  -- Latest request wins; the in-flight request is still consumed before reuse.
  if state.queued then
    state.queued.callback(nil, "superseded")
  end
  state.queued = request
  local ok, err = start()
  if not ok then
    state.queued = nil
    state.last_error = err
    request.callback(nil, err)
    return
  end
  dispatch()
end

function M.request(text, cursor, cwd, callback)
  if text:find("%z") or cwd:find("%z") then
    callback({}, "NUL is not supported")
    return
  end
  enqueue({ text = text, cursor = cursor, cwd = cwd, callback = callback })
end

function M.request_history(limit, callback)
  -- Load disk history on first use without running ZLE completion for an
  -- empty command (which would enumerate commands or files).
  enqueue({ history_limit = limit, callback = callback })
end

function M.history_version()
  return state.history_version
end

function M.history(prefix, limit, extend_only)
  local result, seen = {}, {}
  for _, entry in ipairs(state.history) do
    if
      entry:sub(1, #prefix) == prefix
      and (not extend_only or #entry > #prefix)
      and entry:find("%S")
      and not seen[entry]
      and not entry:find("[\r\n]")
    then
      seen[entry] = true
      result[#result + 1] = entry
      if #result >= (limit or 100) then
        break
      end
    end
  end
  return result
end

function M.remember(command)
  if command:match("%S") and command:sub(1, 1) ~= " " then
    table.insert(state.history, 1, command)
    table.insert(state.session_history, 1, command)
    state.history_version = state.history_version + 1
  end
end

function M.status()
  return {
    ready = state.ready or false,
    running = state.job ~= nil,
    pending = state.pending ~= nil,
    history = #state.history,
    error = state.last_error,
    startup_output = not state.ready and state.output or nil,
  }
end

return M
