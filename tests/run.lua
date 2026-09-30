--[[--
Test entry point.

Run with:  lua tests/run.lua
or:        tools\lua51\lua5.1.exe tests/run.lua
--]]

package.path = "./goodreadskosync.koplugin/?.lua;./tests/?.lua;./tests/?/init.lua;"
    .. package.path

local Harness = require("support.harness")
Harness.install_globals()

require("goodreadskosync.storage").setBaseDir("./tests/.tmp")
require("goodreadskosync.logging").setLevel("ERROR")

local specs = require("specs")
for _, name in ipairs(specs) do
    local file = "./tests/" .. name:gsub("%.", "/") .. ".lua"
    local chunk, err = loadfile(file)
    if not chunk then
        io.write("FAIL: cannot load ", file, ": ", tostring(err), "\n")
        os.exit(1)
    end
    local ok, run_err = pcall(chunk)
    if not ok then
        io.write("FAIL: error in ", file, ": ", tostring(run_err), "\n")
        os.exit(1)
    end
end

Harness.run()
local failures = Harness.report()
os.exit(failures > 0 and 1 or 0)
