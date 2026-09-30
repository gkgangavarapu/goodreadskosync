--[[--
BrowserEngine contract (platform-independent).

The Browser UI and Browser Host talk to an engine only through this interface.
An engine renders **offscreen** and returns a grayscale bitmap, its dimensions,
scroll state and a hitmap. Engines never touch the framebuffer, display, input,
filesystem or processes directly: those belong to the platform layer.

Final architecture:
    Browser UI -> Browser Host -> BrowserEngine -> platform-specific engine

Contract (stable; methods take `self`):
    load(url, cookies, viewport) -> ok, err
        viewport = { w, h, dpi, scale }   (all optional except w/h)
    render() -> {
        bitmap,               -- 8-bit grayscale bytes (engine-defined packing),
        width, height,        -- viewport dimensions in pixels
        scroll_y, scroll_h,   -- current scroll offset and total content height
        hits = { { x, y, w, h, href|action } }
    }
    tap(x, y) -> ok, action|nil
    scroll(dx, dy) -> ok
    back() forward() reload() -> ok, err
    title() -> string
    url() -> string
    capabilities() -> structured table (see Engine.DEFAULT_CAPABILITIES)

@module koplugin.goodreads.browser.engine
--]]

local Engine = {}

Engine.REQUIRED = {
    "load", "render", "tap", "scroll",
    "back", "forward", "reload",
    "title", "url", "capabilities",
}

-- The baseline capability description. Engines override the parts they support.
-- This is intentionally structured (not just js = true/false) so the Host can
-- select engines per platform and describe them to the UI.
Engine.DEFAULT_CAPABILITIES = {
    engine = "unknown",
    html = { level = 0 },
    css = { level = "none", flex = false, grid = false },
    js = { enabled = false, dom = false, engine = nil },
    images = { raster = false, svg = false, formats = {} },
    forms = false,
    https = false,
    cookies = false,
    navigation = false,   -- back/forward/reload
    scrolling = false,
    hitmap = false,
    text_select = false,
}

local function copy(t)
    local out = {}
    for k, v in pairs(t or {}) do
        if type(v) == "table" then out[k] = copy(v) else out[k] = v end
    end
    return out
end

-- Merge an engine's capability table over the defaults (shallow per section).
function Engine.normalize(caps)
    local out = copy(Engine.DEFAULT_CAPABILITIES)
    for k, v in pairs(caps or {}) do
        if type(v) == "table" and type(out[k]) == "table" then
            for k2, v2 in pairs(v) do out[k][k2] = v2 end
        else
            out[k] = v
        end
    end
    return out
end

-- Read a dotted path, e.g. Engine.capability(caps, "images.raster").
function Engine.capability(caps, path)
    local node = caps
    for part in tostring(path):gmatch("[^%.]+") do
        if type(node) ~= "table" then return nil end
        node = node[part]
    end
    return node
end

-- True when `caps` satisfies every truthy dotted requirement.
-- required = { "https", "images.raster", "forms" }
function Engine.meets(caps, required)
    for i = 1, #(required or {}) do
        if not Engine.capability(caps, required[i]) then return false end
    end
    return true
end

-- Whether `engine` implements the contract. Returns true, or false, reason.
function Engine.validate(engine)
    if type(engine) ~= "table" then return false, "engine is not a table" end
    for i = 1, #Engine.REQUIRED do
        local name = Engine.REQUIRED[i]
        if type(engine[name]) ~= "function" then
            return false, "missing method: " .. name
        end
    end
    return true
end

-- A trivial engine for developing the UI without native code.
function Engine.mock()
    local mock = { _url = "about:blank", _title = "Mock engine" }
    function mock:load(url) self._url = url or "about:blank"; return true end
    function mock:render()
        return { bitmap = "", width = 0, height = 0, scroll_y = 0, scroll_h = 0, hits = {} }
    end
    function mock:tap() return true end
    function mock:scroll() return true end
    function mock:back() return true end
    function mock:forward() return true end
    function mock:reload() return true end
    function mock:title() return self._title end
    function mock:url() return self._url end
    function mock:capabilities()
        return Engine.normalize{
            engine = "mock",
            html = { level = 4 }, css = { level = "2.1" },
            images = { raster = true },
            navigation = true, scrolling = true, hitmap = true,
        }
    end
    return mock
end

return Engine
