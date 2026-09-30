--[[--
Browser engine contract.

The plugin's browser UI/host talks to an engine only through this interface, so
a NetSurf-based (or WebKit-based) engine can be swapped in without touching the
UI. Engines render offscreen and return a grayscale bitmap plus a hitmap; they
never touch the Kindle framebuffer.

Contract (all methods take `self`):
  load(url, cookies, viewport) -> ok, err
  render()                     -> { bitmap, width, height, scroll_h, hits = { {rect, href|action} } }
  tap(x, y)  scroll(dy)  back()  forward()  reload() -> ok
  title() -> string   url() -> string
  capabilities() -> { js = bool, css = string, images = bool, forms = bool }

@module koplugin.goodreads.browser.engine
--]]

local Engine = {}

Engine.REQUIRED = {
    "load", "render", "tap", "scroll",
    "back", "forward", "reload",
    "title", "url", "capabilities",
}

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
    local mock = {
        _url = "about:blank",
        _title = "Mock engine",
        _caps = { js = false, css = "2.1", images = true, forms = false },
    }
    function mock:load(url) self._url = url or "about:blank"; return true end
    function mock:render()
        return { bitmap = {}, width = 0, height = 0, scroll_h = 0, hits = {} }
    end
    function mock:tap() return true end
    function mock:scroll() return true end
    function mock:back() return true end
    function mock:forward() return true end
    function mock:reload() return true end
    function mock:title() return self._title end
    function mock:url() return self._url end
    function mock:capabilities() return self._caps end
    return mock
end

return Engine
