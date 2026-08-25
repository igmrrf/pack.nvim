local state = require("pack.state")
local async = require("pack.async")
local pack = require("pack")
local helpers = require("tests.helpers")

describe("pack.async update batching", function()
  after_each(function()
    async.update_recover_ms = 30000
    async.update_batch_size = 5
  end)

  it("split_update_batches caps every batch at the maximum size", function()
    local function sizes(n)
      local items = {}
      for i = 1, n do
        items[i] = "p" .. i
      end
      local out = {}
      for _, b in ipairs(async.split_update_batches(items, 5)) do
        table.insert(out, #b)
      end
      return out
    end

    -- Never above 5 per call; remainders ride a final short batch.
    assert.same({}, async.split_update_batches({}, 5))
    assert.same({ 3 }, sizes(3))
    assert.same({ 5 }, sizes(5))
    assert.same({ 5, 2 }, sizes(7))
    assert.same({ 5, 5, 2 }, sizes(12))
    assert.same({ 5, 5, 5, 5, 3 }, sizes(23))
    assert.same({ 5, 5, 5, 5, 5 }, sizes(25))

    -- Default max comes from update_batch_size.
    async.update_batch_size = 4
    assert.same({ 4, 4 }, (function()
      local out = {}
      for _, b in ipairs(async.split_update_batches({ "a", "b", "c", "d", "e", "f", "g", "h" })) do
        table.insert(out, #b)
      end
      return out
    end)())
  end)

  local function register_installed(count, prefix)
    local names, specs = {}, {}
    for i = 1, count do
      local name = prefix .. i .. ".nvim"
      table.insert(names, name)
      table.insert(specs, { "user/" .. name })
    end
    state.init({ plugins = specs })
    for _, name in ipairs(names) do
      state.get_plugins()[name].status = "installed"
    end
    return names
  end

  local function await_settled(names)
    vim.wait(1000, function()
      local settled = true
      for _, name in ipairs(names) do
        if state.get_plugins()[name].status == "updating" then
          settled = false
        end
      end
      return settled
    end)
  end

  it("U/S flows hand at most 5 names per native call (7 outdated -> two calls: 5+2)", function()
    helpers.reset()
    async.update_recover_ms = 50
    local names = register_installed(7, "batch")
    for _, name in ipairs(names) do
      state.set_behind(name, 1)
    end

    local calls = {}
    local orig_update = pack.native_pack.update
    pack.native_pack.update = function(batch, _opts)
      table.insert(calls, vim.deepcopy(batch))
    end

    async.update_plugins(names)
    vim.wait(2000, function()
      return #calls == 2
    end)
    assert.equals(2, #calls)
    assert.equals(5, #calls[1], "the first batch carries the max of 5 names")
    assert.equals(2, #calls[2], "the remainder rides a final short batch")

    pack.native_pack.update = orig_update
    await_settled(names)
  end)

  it("splits large target lists into capped batches (12 -> three calls: 5+5+2)", function()
    helpers.reset()
    async.update_recover_ms = 50
    local names = register_installed(12, "even")

    local calls = {}
    local orig_update = pack.native_pack.update
    pack.native_pack.update = function(batch, _opts)
      table.insert(calls, vim.deepcopy(batch))
    end

    async.update_plugins(names)
    vim.wait(2000, function()
      return #calls == 3
    end)
    assert.equals(3, #calls)
    assert.equals(5, #calls[1])
    assert.equals(5, #calls[2])
    assert.equals(2, #calls[3])

    pack.native_pack.update = orig_update
    await_settled(names)
  end)
end)

describe("pack.async use_git background operations", function()
  local orig_system
  local orig_update_recover_ms

  before_each(function()
    helpers.reset()
    orig_system = vim.system
    orig_update_recover_ms = async.update_recover_ms
    async.update_recover_ms = 60
    pack.config.use_git = true
    if pack.config.ui then
      pack.config.ui.auto_open = false
    end
  end)

  after_each(function()
    vim.system = orig_system
    async.update_recover_ms = orig_update_recover_ms
    pack.config.use_git = false
  end)

  -- Minimal vim.system stand-in: replays stdout, then completes with `code`.
  local function fake_system(commands, code)
    return function(cmd, opts, on_exit)
      table.insert(commands, { cmd = vim.deepcopy(cmd), cwd = opts and opts.cwd or nil })
      if opts and opts.stdout then
        opts.stdout(nil, "")
      end
      vim.schedule(function()
        on_exit({ code = code })
      end)
      return {}
    end
  end

  it("updates move HEAD with background git, then native update reconciles the lockfile", function()
    local dir = vim.fn.tempname() .. "-bgplug"
    vim.fn.mkdir(dir .. "/.git", "p")
    state.init({ plugins = { { "user/bgplug.nvim", branch = "main" } } })
    local p = state.get_plugins()["bgplug.nvim"]
    p.status = "installed"
    p.dir = dir
    p.behind = 2

    local commands, native_calls = {}, {}
    vim.system = fake_system(commands, 0)
    local orig_update = pack.native_pack.update
    pack.native_pack.update = function(names, _opts)
      native_calls[#native_calls + 1] = vim.deepcopy(names)
    end

    async.update_plugins({ "bgplug.nvim" })

    vim.wait(3000, function()
      return #native_calls == 1
    end)
    pack.native_pack.update = orig_update

    -- fetch + ff-only merge ran against the plugin worktree...
    local saw_fetch, saw_merge = false, false
    for _, c in ipairs(commands) do
      if c.cmd[2] == "fetch" then
        saw_fetch = true
        assert.equals(dir, c.cwd)
      elseif c.cmd[2] == "merge" then
        saw_merge = true
        assert.same({ "merge", "--ff-only", "origin/main" }, { c.cmd[2], c.cmd[3], c.cmd[4] })
      end
    end
    assert.is_true(saw_fetch, "background update must fetch origin")
    assert.is_true(saw_merge, "background update must fast-forward to the upstream ref")

    -- ...and native still runs afterwards to keep the lockfile in sync.
    assert.equals(1, #native_calls)
    assert.same({ "bgplug.nvim" }, native_calls[1])
    vim.wait(1000, function()
      return p.status ~= "updating"
    end)
  end)

  it("falls back to native update for pinned plugins instead of background git", function()
    state.init({ plugins = { { "user/pinned.nvim", tag = "v1.0.0" } } })
    local p = state.get_plugins()["pinned.nvim"]
    p.status = "installed"
    local dir = vim.fn.tempname() .. "-pinned"
    vim.fn.mkdir(dir .. "/.git", "p")
    p.dir = dir

    local commands, native_calls = {}, {}
    vim.system = fake_system(commands, 0)
    local orig_update = pack.native_pack.update
    pack.native_pack.update = function(names, _opts)
      native_calls[#native_calls + 1] = vim.deepcopy(names)
    end

    async.update_plugins({ "pinned.nvim" })
    vim.wait(2000, function()
      return #native_calls == 1
    end)
    pack.native_pack.update = orig_update

    assert.equals(0, #commands, "pinned plugins must not spawn background git jobs")
    assert.same({ "pinned.nvim" }, native_calls[1])
  end)

  it("mixes pinned and tracking plugins: background git for worktrees, one final native pass", function()
    local dirs, names = {}, {}
    -- Three plain tracking-branch worktrees...
    for i = 1, 3 do
      local name = "mix" .. i .. ".nvim"
      dirs[name] = vim.fn.tempname() .. "-mix" .. i
      vim.fn.mkdir(dirs[name] .. "/.git", "p")
      table.insert(names, name)
    end
    -- ...and one tag-pinned plugin that must stay on the native path.
    table.insert(names, "mixpinned.nvim")
    state.init({
      plugins = {
        { "user/mixpinned.nvim", tag = "v1.0.0" },
        { "user/mix1.nvim", branch = "main" },
        { "user/mix2.nvim", branch = "main" },
        { "user/mix3.nvim", branch = "main" },
      },
    })
    for _, name in ipairs(names) do
      local p = state.get_plugins()[name]
      p.status = "installed"
      if dirs[name] then
        p.dir = dirs[name]
        p.behind = 1
      end
    end

    local commands, native_calls = {}, {}
    vim.system = fake_system(commands, 0)
    local orig_update = pack.native_pack.update
    pack.native_pack.update = function(batch, _opts)
      native_calls[#native_calls + 1] = vim.deepcopy(batch)
    end

    async.update_plugins(names)

    vim.wait(3000, function()
      return #native_calls == 1
    end)
    pack.native_pack.update = orig_update

    -- Background git fetched ONLY the tracking worktrees.
    local fetch_dirs = {}
    for _, c in ipairs(commands) do
      if c.cmd[2] == "fetch" then
        table.insert(fetch_dirs, c.cwd)
      end
    end
    assert.equals(3, #fetch_dirs, "only the three supported plugins get background git jobs")

    -- Everything rides ONE aggregated native pass (pins included).
    assert.equals(1, #native_calls)
    table.sort(native_calls[1])
    assert.same({ "mix1.nvim", "mix2.nvim", "mix3.nvim", "mixpinned.nvim" }, native_calls[1])

    vim.wait(1000, function()
      local settled = true
      for _, name in ipairs(names) do
        if state.get_plugins()[name].status == "updating" then
          settled = false
        end
      end
      return settled
    end)
  end)

  it("restores status and skips the lockfile pass when background git fails", function()
    local dir = vim.fn.tempname() .. "-bgfail"
    vim.fn.mkdir(dir .. "/.git", "p")
    state.init({ plugins = { { "user/bgfail.nvim", branch = "main" } } })
    local p = state.get_plugins()["bgfail.nvim"]
    p.status = "installed"
    p.dir = dir

    local errors, native_called = {}, false
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then
        errors[#errors + 1] = tostring(msg)
      end
    end
    vim.system = fake_system({}, 128)
    local orig_update = pack.native_pack.update
    pack.native_pack.update = function()
      native_called = true
    end

    async.update_plugins({ "bgfail.nvim" })

    vim.wait(2000, function()
      return p.status ~= "updating"
    end)
    vim.notify = orig_notify
    pack.native_pack.update = orig_update

    assert.equals("installed", p.status, "failed background fetch must not strand the plugin in 'updating'")
    assert.is_false(native_called, "no lockfile reconciliation when the transfer failed")
    assert.is_true(#errors > 0, "the failure must be reported")
  end)

  it("installs missing plugins with a background clone, then native add registers them + lockfile", function()
    state.init({ plugins = { { "user/bgnew.nvim", branch = "main" } } })
    local ns = state.to_native_spec(state.get_plugins()["bgnew.nvim"])
    assert.is_not_nil(ns)

    local commands, added = {}, {}
    vim.system = fake_system(commands, 0)
    local orig_add = pack.native_pack.add
    pack.native_pack.add = function(specs, opts)
      added[#added + 1] = vim.deepcopy(specs)
      if opts and opts.load then
        opts.load({ spec = specs[1], path = state.native_opt_dir() .. "/" .. specs[1].name })
      end
    end

    pack._install_and_load({ ns }, false)

    vim.wait(3000, function()
      return #added == 1
    end)
    pack.native_pack.add = orig_add

    -- Background clone targeted the shared native opt directory...
    assert.equals(1, #commands)
    assert.equals("clone", commands[1].cmd[2])
    local want_dir = vim.fs.joinpath(state.native_opt_dir(), "bgnew.nvim")
    assert.equals(want_dir, commands[1].cmd[#commands[1].cmd])
    assert.is_true(vim.list_contains(commands[1].cmd, "--branch"))
    assert.is_true(vim.list_contains(commands[1].cmd, "main"))

    -- ...and native adopted it (registration + lockfile entry).
    assert.equals(1, #added)
    assert.equals("bgnew.nvim", added[1][1].name)
    vim.wait(1000, function()
      return state.get_plugins()["bgnew.nvim"].status ~= "installing"
    end)
  end)

  it("marks an install failed, cleans the partial clone, and skips native add when the clone fails", function()
    state.init({ plugins = { { "user/bgbad.nvim" } } })
    local ns = state.to_native_spec(state.get_plugins()["bgbad.nvim"])

    -- Simulate git leaving a half-cloned target behind before failing.
    local partial_dir = nil
    vim.system = function(cmd, _opts, on_exit)
      if cmd[2] == "clone" then
        partial_dir = cmd[#cmd]
        vim.fn.mkdir(partial_dir, "p")
        vim.fn.writefile({ "junk" }, partial_dir .. "/leftover.txt")
      end
      vim.schedule(function()
        on_exit({ code = 128 })
      end)
      return {}
    end

    local errors, added = {}, false
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then
        errors[#errors + 1] = tostring(msg)
      end
    end
    local orig_add = pack.native_pack.add
    pack.native_pack.add = function()
      added = true
    end

    pack._install_and_load({ ns }, false)

    vim.wait(2000, function()
      return state.get_plugins()["bgbad.nvim"].status == "error"
    end)
    vim.notify = orig_notify
    pack.native_pack.add = orig_add

    assert.equals("error", state.get_plugins()["bgbad.nvim"].status)
    assert.is_false(added, "native add must not adopt a half-cloned directory")
    assert.is_true(#errors > 0)
    -- The half-written directory is removed so the next startup retries cleanly.
    assert.is_not_nil(partial_dir, "the failed clone must have had a target directory")
    assert.equals(0, vim.fn.isdirectory(partial_dir), "a failed clone must not leave debris behind")
  end)

  it("never passes a dash-leading version to git as a ref name", function()
    state.init({ plugins = { { "user/dashy.nvim" } } })
    local p = state.get_plugins()["dashy.nvim"]
    -- Hand-built native spec: simulates any caller supplying a hostile pin,
    -- bypassing normalize()'s own leading-dash guard on branch/tag/commit.
    local ns = { src = p.url, name = p.name, version = "-oProxyCommand=evil", data = {} }

    local commands, added = {}, {}
    vim.system = fake_system(commands, 0)
    local orig_add = pack.native_pack.add
    pack.native_pack.add = function(specs, opts)
      added[#added + 1] = vim.deepcopy(specs)
      if opts and opts.load then
        opts.load({ spec = specs[1], path = state.native_opt_dir() .. "/" .. specs[1].name })
      end
    end

    pack._install_and_load({ ns }, false)

    vim.wait(3000, function()
      return #added == 1
    end)
    pack.native_pack.add = orig_add

    -- A default clone ran; the hostile value never appears in the git argv...
    assert.equals(1, #commands, "one plain clone, no checkout detour")
    assert.same(4, #commands[1].cmd, "argv is exactly git clone <src> <dir>")
    assert.is_false(
      vim.list_contains(commands[1].cmd, "-oProxyCommand=evil"),
      "--branch must not receive a dash-leading value"
    )
    -- ...and native still adopts the install with the pin intact for enforcement.
    assert.equals(1, #added)
    assert.equals("-oProxyCommand=evil", added[1][1].version)
  end)
end)
