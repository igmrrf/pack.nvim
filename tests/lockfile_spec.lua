local lockfile = require("pack.lockfile")

-- Build a throwaway git repo with a single commit; returns its dir and HEAD sha.
local function make_git_repo(dir)
  vim.fn.mkdir(dir, "p")
  vim.fn.system({ "git", "-C", dir, "init", "-q" })
  vim.fn.system({ "git", "-C", dir, "config", "user.email", "t@t" })
  vim.fn.system({ "git", "-C", dir, "config", "user.name", "t" })
  vim.fn.writefile({ "x" }, dir .. "/f")
  vim.fn.system({ "git", "-C", dir, "add", "-A" })
  vim.fn.system({ "git", "-C", dir, "commit", "-qm", "init" })
  return dir, vim.trim(vim.fn.system({ "git", "-C", dir, "rev-parse", "HEAD" }))
end

local function write_lock(path, tbl)
  vim.fn.writefile(vim.split(vim.json.encode(tbl), "\n"), path)
end

describe("pack.lockfile", function()
  local lock_path
  local orig_path

  before_each(function()
    lock_path = vim.fn.tempname() .. "-nvim-pack-lock.json"
    orig_path = lockfile.path
    lockfile.path = function()
      return lock_path
    end
  end)

  after_each(function()
    lockfile.path = orig_path
    if vim.fn.filereadable(lock_path) == 1 then
      vim.fn.delete(lock_path)
    end
  end)

  describe("read", function()
    it("returns nil + reason when the file is absent", function()
      local lock, reason = lockfile.read()
      assert.is_nil(lock)
      assert.equals("no lockfile", reason)
    end)

    it("returns nil + reason on invalid json / missing plugins table", function()
      vim.fn.writefile({ "{ not json" }, lock_path)
      local lock, reason = lockfile.read()
      assert.is_nil(lock)
      assert.equals("invalid json", reason)
    end)

    it("decodes a well-formed lockfile", function()
      write_lock(lock_path, { version = 1, plugins = { foo = { src = "u/foo", rev = "abc" } } })
      local lock = lockfile.read()
      assert.equals(1, lock.version)
      assert.equals("abc", lock.plugins.foo.rev)
    end)
  end)

  describe("update_entry", function()
    it("writes a plugin entry with the on-disk HEAD, in native's format", function()
      local dir, head = make_git_repo(vim.fn.tempname() .. "-foo")
      assert.is_true(lockfile.update_entry("foo.nvim", "https://x/foo", dir))

      local lock = lockfile.read()
      assert.equals(head, lock.plugins["foo.nvim"].rev)
      assert.equals("https://x/foo", lock.plugins["foo.nvim"].src)

      -- Native's serialization: 2-space indent + sorted keys + trailing newline.
      local raw = table.concat(vim.fn.readfile(lock_path), "\n") .. "\n"
      assert.is_true(raw:find('\n  "plugins"', 1, true) ~= nil, "expected 2-space indented keys")
      assert.equals("\n", raw:sub(-1), "expected a trailing newline")
    end)
  end)

  describe("ensure_synced", function()
    it("adds missing on-disk plugins and is a no-op when already present", function()
      local dir = make_git_repo(vim.fn.tempname() .. "-bar")
      local plugins = { ["bar.nvim"] = { dir = dir, url = "https://x/bar" } }

      assert.is_true(lockfile.ensure_synced(plugins))
      assert.is_not_nil(lockfile.read().plugins["bar.nvim"])

      -- Second call: entry already present -> no rewrite needed, still succeeds.
      local before = vim.fn.readfile(lock_path)
      assert.is_true(lockfile.ensure_synced(plugins))
      assert.same(before, vim.fn.readfile(lock_path))
    end)
  end)

  describe("divergences / repair", function()
    it("reports divergence when lockfile rev differs from HEAD and repair realigns it forward", function()
      local opt_dir = vim.fn.tempname() .. "-opt"
      vim.fn.mkdir(opt_dir, "p")
      local _, head = make_git_repo(opt_dir .. "/plug.nvim")

      -- Lockfile records a stale rev.
      write_lock(lock_path, { version = 1, plugins = { ["plug.nvim"] = { src = "u/plug", rev = "deadbeef" } } })

      local diverged = lockfile.divergences(opt_dir)
      assert.equals(1, #diverged)
      assert.equals("plug.nvim", diverged[1].name)
      assert.equals("deadbeef", diverged[1].expected)
      assert.equals(head, diverged[1].actual)

      -- Repair pulls the lockfile forward to the on-disk HEAD.
      local fixed = lockfile.repair(opt_dir)
      assert.same({ "plug.nvim" }, fixed)
      assert.equals(head, lockfile.read().plugins["plug.nvim"].rev)

      -- Now aligned: divergences empty and repair is a no-op.
      assert.equals(0, #lockfile.divergences(opt_dir))
      assert.same({}, lockfile.repair(opt_dir))
    end)
  end)
end)
