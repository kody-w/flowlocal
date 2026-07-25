-- Hammerspoon entry point.
-- The ipc listener gives you the `hs` shell CLI, which RAPP Voice's tests
-- (tools/dryrun.sh, tools/statemachine.lua) use to drive the real pipeline from a
-- terminal. It is local-only. Drop these lines if you do not want it — the tests
-- will stop working, dictation will not.
-- NB: require("hs.ipc") is what starts the listener, so it must run every load.
-- Only the symlink install is conditional, so it stops rewriting Homebrew paths
-- (and warning about the man page) on every reload.
require("hs.ipc")
if not hs.fs.attributes("/opt/homebrew/bin/hs") then
  hs.ipc.cliInstall("/opt/homebrew")
end

require("rappvoice")
