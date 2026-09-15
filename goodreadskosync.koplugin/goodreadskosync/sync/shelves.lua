--[[--
Canonical shelf policy.

@module koplugin.goodreads.sync.shelves
--]]

local Constants = require("goodreadskosync.constants")

local Shelves = {}

function Shelves.isValid(shelf)
    return shelf == Constants.SHELF.WANT_TO_READ
        or shelf == Constants.SHELF.CURRENTLY_READING
        or shelf == Constants.SHELF.READ
        or shelf == Constants.SHELF.DID_NOT_FINISH
end

-- Derive the desired shelf from reading state.
-- Opening a book with no progress does NOT imply "Currently Reading", and a
-- percentage is never treated as proof of completion.
function Shelves.forState(percent, status, opts)
    opts = opts or {}
    if opts.shelf_override and Shelves.isValid(opts.shelf_override) then
        return opts.shelf_override
    end
    if status == "complete" then
        return Constants.SHELF.READ
    end
    -- "abandoned" (Did Not Finish) must never move a book to Currently
    -- Reading; leave the shelf alone.
    if status == "abandoned" then
        return nil
    end
    if opts.allow_percent_completion and percent and percent >= 99 then
        return Constants.SHELF.READ
    end
    if type(percent) == "number" and percent > 0 then
        return Constants.SHELF.CURRENTLY_READING
    end
    return nil
end

function Shelves.label(shelf)
    if shelf == Constants.SHELF.WANT_TO_READ then return "Want to Read" end
    if shelf == Constants.SHELF.CURRENTLY_READING then return "Currently Reading" end
    if shelf == Constants.SHELF.READ then return "Read" end
    if shelf == Constants.SHELF.DID_NOT_FINISH then return "Did Not Finish" end
    return "Unknown"
end

-- Whether an automatic policy may change the current shelf. A user override
-- suppresses automatic changes until it is consumed.
function Shelves.shouldApply(current, desired, opts)
    opts = opts or {}
    if not desired then return false end
    if current == desired then return false end
    if opts.user_override and opts.user_override ~= desired then
        return false
    end
    return true
end

return Shelves
