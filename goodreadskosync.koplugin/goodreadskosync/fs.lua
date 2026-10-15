--[[--
Filesystem helper: directory creation that does not depend on a shell.

KOReader ships a recursive mkdir at `util.makePath`, in the **frontend** util
module - `ffi/util` has `realpath`, `dirname`, `purgeDir` and friends but no
`makePath`. The plugin prefers it: creating the plugin's own settings folder on
Android should not have to assume a working shell and `mkdir` on `PATH`. The
shell command stays as the fallback so the offline test suite - and any unusual
build - still works.

@module koplugin.goodreads.fs
--]]

local Fs = {}

-- Create `dir` and its parents. Best effort: returns true once a method has
-- been tried, not a promise that the directory now exists.
function Fs.makeDir(dir)
    if type(dir) ~= "string" or dir == "" then return false end

    local ok, util = pcall(require, "util")
    if ok and type(util) == "table" and type(util.makePath) == "function" then
        -- `makePath` returns true on success and false on failure; only fall
        -- through to the shell when it reports failure.
        local called, done = pcall(util.makePath, dir)
        if called and done ~= false then return true end
    end

    if os.getenv("OS") ~= nil then
        os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
    else
        os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
    end
    return true
end

return Fs
