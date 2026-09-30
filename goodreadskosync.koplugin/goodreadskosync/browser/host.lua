--[[--
Browser Host: platform-independent engine selection.

The Host chooses a local engine by capability and availability. It never
switches automatically: the user's choice is honoured, with CRE as the safe
fallback. It also builds the viewport passed to engines, so no engine hard-codes
device dimensions.

@module koplugin.goodreads.browser.host
--]]

local Engine = require("goodreadskosync.browser.engine")

local Host = {}

Host.CRE = "cre"
Host.NETSURF = "netsurf"

-- Capability descriptors for the known backends, used to select an engine for a
-- platform and to build the compatibility matrix. CRE is KOReader's own HTML
-- engine (the existing reader); NetSurf is the offscreen native engine.
Host.CAPABILITIES = {
    [Host.CRE] = Engine.normalize{
        engine = "cre",
        html = { level = 4 },
        css = { level = "partial" },
        images = { raster = true },
        forms = false,
        https = true,
        cookies = true,
        navigation = true,
        scrolling = true,
        hitmap = false,
    },
    [Host.NETSURF] = Engine.normalize{
        engine = "netsurf",
        html = { level = 4 },
        css = { level = "2.1" },
        images = { raster = true, formats = { "png", "jpeg", "gif", "bmp" } },
        forms = true,
        https = true,
        cookies = true,
        navigation = true,
        scrolling = true,
        hitmap = true,
    },
}

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
function Host.resolve(requested, netsurf_bin)
    if requested == Host.NETSURF then
        if Host.binary_available(netsurf_bin) then
            return Host.NETSURF, "ok"
        end
        return Host.CRE, "netsurf helper not found"
    end
    return Host.CRE, "ok"
end

-- Pick the first candidate that meets `required` (dotted capability list) and
-- is available. candidates are tried in preference order (most capable first).
-- available: optional function(name) -> bool.
function Host.choose(candidates, required, available)
    for i = 1, #(candidates or {}) do
        local name = candidates[i]
        local caps = Host.CAPABILITIES[name]
        if caps and (not available or available(name)) and Engine.meets(caps, required) then
            return name
        end
    end
    return nil
end

-- Build a viewport descriptor for an engine. No device dimensions are assumed;
-- callers pass the real screen size and optional dpi/scale.
function Host.viewport(w, h, opts)
    opts = opts or {}
    return {
        w = tonumber(w),
        h = tonumber(h),
        dpi = tonumber(opts.dpi) or nil,
        scale = tonumber(opts.scale) or nil,
    }
end

-- Create an engine instance for a backend. The UI asks the Host for engines
-- rather than constructing them itself, so engine choice stays in one place.
-- Returns an engine, or nil+reason when the backend cannot be created (e.g. the
-- NetSurf helper is missing).
function Host.create_engine(name, opts)
    opts = opts or {}
    if name == Host.NETSURF then
        if not Host.binary_available(opts.bin) then
            return nil, "netsurf helper not found"
        end
        local NetSurf = require("goodreadskosync.browser.engines.netsurf")
        return NetSurf.new(opts)
    end
    return nil, "unsupported engine: " .. tostring(name)
end

return Host
