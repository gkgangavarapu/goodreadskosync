--[[--
Browser host: engine selection and availability.

The host decides which local engine the browser uses. CRE (KOReader's own HTML
engine, reached through the existing reader) is always available and is the
default. NetSurf is opt-in and only selected once its native helper exists on
the device. Nothing here switches engines automatically.

@module koplugin.goodreads.browser.host
--]]

local Host = {}

Host.CRE = "cre"
Host.NETSURF = "netsurf"

-- Whether a helper binary exists and is a regular file.
function Host.binary_available(path)
    if type(path) ~= "string" or path == "" then return false end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs then
        return lfs.attributes(path, "mode") == "file"
    end
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

-- Resolve the engine to actually use. `requested` is the user's setting; if
-- NetSurf is requested but its helper is missing, fall back to CRE.
-- Returns engine_name, reason.
function Host.resolve(requested, netsurf_bin)
    if requested == Host.NETSURF then
        if Host.binary_available(netsurf_bin) then
            return Host.NETSURF, "ok"
        end
        return Host.CRE, "netsurf helper not found"
    end
    return Host.CRE, "ok"
end

return Host
