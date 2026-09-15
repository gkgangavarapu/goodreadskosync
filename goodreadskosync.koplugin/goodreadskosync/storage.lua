--[[--
Persistent storage for the plugin.

Each concern lives in its own file (mappings, sync state, queue, ...) so that
a corrupt queue can never take the book mappings down with it. When KOReader's
`LuaSettings` is available it is used directly; otherwise a self-contained
serializer keeps the module usable from the unit test suite.

@module koplugin.goodreads.storage
--]]

local Constants = require("goodreadskosync.constants")
local Logging = require("goodreadskosync.logging")

local Storage = {}

local base_dir_override = nil
local LuaSettings = select(2, pcall(require, "luasettings"))

-- Windows is only used for the offline test suite; KOReader devices are Linux.
local IS_WINDOWS = os.getenv("OS") ~= nil

--------------------------------------------------------------------------------
-- Fallback serializer
--------------------------------------------------------------------------------

local function serialize(value)
    local t = type(value)
    if t == "nil" then
        return "nil"
    elseif t == "number" or t == "boolean" then
        return tostring(value)
    elseif t == "string" then
        return string.format("%q", value)
    elseif t == "table" then
        local parts = { "{" }
        -- Emit array part first for readability, then remaining keys.
        local array_len = #value
        for i = 1, array_len do
            parts[#parts + 1] = serialize(value[i]) .. ","
        end
        for k, v in pairs(value) do
            local is_array_index = type(k) == "number" and k >= 1
                and k <= array_len and k == math.floor(k)
            if not is_array_index then
                local key_repr
                if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                    key_repr = k
                else
                    key_repr = "[" .. serialize(k) .. "]"
                end
                parts[#parts + 1] = key_repr .. "=" .. serialize(v) .. ","
            end
        end
        parts[#parts + 1] = "}"
        return table.concat(parts)
    end
    return "nil"
end

--------------------------------------------------------------------------------
-- Backends
--------------------------------------------------------------------------------

local Store = {}
Store.__index = Store

function Store:get(key, default)
    local value = self.data[key]
    if value == nil then return default end
    return value
end

function Store:set(key, value)
    self.data[key] = value
    self.dirty = true
end

function Store:delete(key)
    self.data[key] = nil
    self.dirty = true
end

function Store:has(key)
    return self.data[key] ~= nil
end

function Store:keys()
    local keys = {}
    for k in pairs(self.data) do keys[#keys + 1] = k end
    return keys
end

function Store:flush()
    if not self.dirty then return true end
    local ok
    if self.ls then
        for k, v in pairs(self.data) do
            self.ls:saveSetting(k, v)
        end
        ok = pcall(function() self.ls:flush() end)
    else
        ok = self:_writeFile()
    end
    if ok then self.dirty = false end
    return ok
end

function Store:_writeFile()
    local dir = self.dir
    if IS_WINDOWS then
        os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
    else
        os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
    end
    local tmp = self.path .. ".tmp"
    local file = io.open(tmp, "w")
    if not file then
        Logging.warn("storage: cannot write", self.path)
        return false
    end
    file:write("return ", serialize(self.data), "\n")
    file:close()
    os.remove(self.path)
    local ok = os.rename(tmp, self.path)
    if not ok then
        -- Windows cannot rename over an existing file; remove first.
        os.remove(self.path)
        ok = os.rename(tmp, self.path)
    end
    return ok and true or false
end

local function fallback_store(path)
    local data = {}
    local file = io.open(path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local chunk = loadstring(content)
        if chunk then
            local ok, loaded = pcall(chunk)
            if ok and type(loaded) == "table" then data = loaded end
        end
    end
    local dir = path:match("^(.*)[/\\][^/\\]*$") or "."
    return setmetatable({
        data = data,
        path = path,
        dir = dir,
        dirty = false,
    }, Store)
end

local function luasettings_store(path)
    local ls = LuaSettings:open(path)
    local data = {}
    -- LuaSettings stores a flat table; materialize it for a uniform interface.
    if ls.data then
        for k, v in pairs(ls.data) do data[k] = v end
    end
    local store = setmetatable({
        data = data,
        path = path,
        dir = path:match("^(.*)[/\\][^/\\]*$") or ".",
        ls = ls,
        dirty = false,
    }, Store)
    return store
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function Storage.getBaseDir()
    if base_dir_override then return base_dir_override end
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage then
        return DataStorage:getSettingsDir() .. "/goodreadskosync"
    end
    return "./.goodreads-test"
end

function Storage.setBaseDir(dir)
    base_dir_override = dir
end

function Storage.open(name)
    local path = Storage.getBaseDir() .. "/" .. name .. ".lua"
    if LuaSettings and not base_dir_override then
        return luasettings_store(path)
    end
    return fallback_store(path)
end

-- Test helper: remove every storage file and reset the override.
function Storage.reset()
    local dir = Storage.getBaseDir()
    local names = {
        Constants.STORAGE.ACCOUNT,
        Constants.STORAGE.SESSION,
        Constants.STORAGE.CREDENTIALS,
        Constants.STORAGE.MAPPINGS,
        Constants.STORAGE.BOOK_SETTINGS,
        Constants.STORAGE.SYNC_STATE,
        Constants.STORAGE.QUEUE,
        Constants.STORAGE.SEARCH_CACHE,
        Constants.STORAGE.SETTINGS,
        "mock_state",
        "mock_account",
    }
    for _, name in ipairs(names) do
        os.remove(dir .. "/" .. name .. ".lua")
        os.remove(dir .. "/" .. name .. ".lua.tmp")
    end
end

Storage.serialize = serialize
Storage._fallback_store = fallback_store

return Storage
