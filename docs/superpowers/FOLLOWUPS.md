# Follow-ups

## Pre-existing: ftdetect-cache test flake (unrelated to dual-style tracking)

`tests/config_and_cache_spec.lua` — "writes the ftdetect cache for a lazy installed
plugin during flush" (assert at :112, "cache must reference the ftdetect file")
flakes intermittently.

- **Proven pre-existing:** at merge-base `789232a`, full `make test` flakes ~3/8 runs;
  the spec run alone is 0/12. The dual-style-tracking branch did not touch this spec
  or `lua/pack/loader.lua`.
- **Cause:** `loader.build_cache` (lua/pack/loader.lua:251) writes a *shared* path
  `stdpath('data')/pack_ftdetect_cache.lua`. `build_cache` is invoked from
  `flush_pending` and via a `vim.schedule` (loader.lua:204). In a single-process full
  `make test` run, a scheduled `build_cache` from one test can overwrite the cache
  file while another test asserts on it → race → flake.
- **Fix direction:** make the cache path test-overridable (mirror
  `persist._set_path_for_testing`) so each test uses an isolated file, and/or ensure no
  scheduled `build_cache` outlives the test that queued it. Contained change; add a
  regression run.
