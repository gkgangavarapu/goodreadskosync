--[[--
Small table helpers.

@module koplugin.goodreads.table_util
--]]

local TableUtil = {}

-- Follow a dotted path (e.g. "a.b.c") through nested tables.
function TableUtil.dig(t, path)
    if type(t) ~= "table" or type(path) ~= "string" then return nil end
    local current = t
    for key in path:gmatch("[^.]+") do
        if type(current) ~= "table" then return nil end
        current = current[key]
    end
    return current
end

function TableUtil.contains(list, value)
    if type(list) ~= "table" then return false end
    for _, item in ipairs(list) do
        if item == value then return true end
    end
    return false
end

-- Binary search for `value` in a sorted ascending array; returns the index or
-- nil. Used by the page mapper.
function TableUtil.binSearch(list, value)
    if type(list) ~= "table" or type(value) ~= "number" then return nil end
    local low, high = 1, #list
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local item = list[mid]
        if item == value then
            return mid
        elseif item < value then
            low = mid + 1
        else
            high = mid - 1
        end
    end
    return nil
end

return TableUtil
