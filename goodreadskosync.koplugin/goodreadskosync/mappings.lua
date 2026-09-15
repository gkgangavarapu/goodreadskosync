--[[--
Permanent local book -> Goodreads identity mappings.

Mappings survive restarts, renames, and moves because the key is derived from
identifiers/metadata, never from the file path.

@module koplugin.goodreads.mappings
--]]

local Constants = require("goodreadskosync.constants")
local Storage = require("goodreadskosync.storage")

local Mappings = {}

local function store()
    return Storage.open(Constants.STORAGE.MAPPINGS)
end

function Mappings.get(local_key)
    if not local_key then return nil end
    local all = store():get("books", {})
    return all[local_key]
end

function Mappings.put(local_key, record)
    if not local_key or type(record) ~= "table" then return false end
    local s = store()
    local all = s:get("books", {})
    local now = os.time()
    record.local_key = local_key
    record.updated_at = now
    record.created_at = record.created_at or (all[local_key] and all[local_key].created_at) or now
    all[local_key] = record
    s:set("books", all)
    return s:flush()
end

function Mappings.forget(local_key)
    local s = store()
    local all = s:get("books", {})
    if all[local_key] == nil then return false end
    all[local_key] = nil
    s:set("books", all)
    return s:flush()
end

function Mappings.all()
    return store():get("books", {})
end

function Mappings.count()
    local n = 0
    for _ in pairs(Mappings.all()) do n = n + 1 end
    return n
end

return Mappings
