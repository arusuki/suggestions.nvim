local M = {}

-- Each completion owns its processes. Cancellation also suppresses callbacks
-- already queued on Neovim's main loop.
function M.request(config)
  local request = { cancelled = false, jobs = {} }

  function request.cancel()
    request.cancelled = true
    for job in pairs(request.jobs) do
      pcall(job.kill, job, 9)
    end
    request.jobs = {}
  end

  function request.run(argv, opts, callback)
    if request.cancelled then
      return
    end
    opts = vim.tbl_extend("force", { timeout = config.timeout_ms }, opts or {})
    local job
    local ok, err = pcall(function()
      job = vim.system(argv, opts, function(result)
        vim.schedule(function()
          request.jobs[job] = nil
          if not request.cancelled then
            callback(result)
          end
        end)
      end)
    end)
    if ok then
      request.jobs[job] = true
    else
      callback({ code = -1, stderr = tostring(err) })
    end
  end

  function request.filter(candidates, query, case, callback)
    local values, seen = {}, {}
    for _, value in ipairs(candidates) do
      if value ~= "" and not value:find("[%z\r\n]") and not seen[value] then
        values[#values + 1], seen[value] = value, true
      end
    end
    if #values == 0 then
      callback({})
      return
    end
    local argv = {
      config.executable,
      "--read0",
      "--print0",
      "--no-extended",
      "--algo=v2",
      "--sort",
      "--tiebreak=index",
      "--filter=" .. query,
    }
    -- Smart-case is fzf's default. Use the short case flags because older
    -- distribution packages (including Ubuntu's 0.44.1) lack the long forms.
    if case == "--ignore-case" then
      argv[#argv + 1] = "-i"
    elseif case == "--no-ignore-case" then
      argv[#argv + 1] = "+i"
    end
    request.run(argv, {
      stdin = table.concat(values, "\0") .. "\0",
      -- User terminal options must not change the machine-readable protocol.
      env = { FZF_DEFAULT_OPTS = "", FZF_DEFAULT_OPTS_FILE = "" },
    }, function(result)
      if result.code ~= 0 and result.code ~= 1 then
        callback(nil, "fzf failed (" .. result.code .. "): " .. (result.stderr or ""))
        return
      end
      callback(vim.split(result.stdout or "", "\0", { plain = true, trimempty = true }))
    end)
  end

  return request
end

return M
