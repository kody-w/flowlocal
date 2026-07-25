-- Hammerspoon entry point.
-- The ipc bootstrap gives you the `hs` shell CLI, which FlowLocal's dry-run
-- tests (tools/dryrun.sh) use to drive the real pipeline from a terminal.
require("hs.ipc"); hs.ipc.cliInstall("/opt/homebrew")

require("flowlocal")
