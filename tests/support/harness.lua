--[[--
Tiny dependency-free test harness.

Provides `describe`/`it`/assertions as globals while a spec file is being
loaded, then runs every registered case. No luarocks/busted dependency, which
keeps the suite runnable with the vendored portable Lua 5.1.

@module tests.support.harness
--]]

local Harness = {}

local suites = {}
local path_stack = {}
local passed = 0
local failed = 0
local failures = {}

function Harness.describe(name, fn)
    path_stack[#path_stack + 1] = name
    local ok, err = pcall(fn)
    if not ok then
        failed = failed + 1
        failures[#failures + 1] = {
            name = table.concat(path_stack, " > ") .. " (load error)",
            err = tostring(err),
        }
    end
    path_stack[#path_stack] = nil
end

function Harness.it(name, fn)
    suites[#suites + 1] = {
        name = table.concat(path_stack, " > ") .. " > " .. name,
        fn = fn,
    }
end

local function fail(message, level)
    error(message or "assertion failed", level or 3)
end

function Harness.assert_true(value, message)
    if not value then fail(message or ("expected truthy, got " .. tostring(value))) end
end

function Harness.assert_false(value, message)
    if value then fail(message or ("expected falsy, got " .. tostring(value))) end
end

function Harness.assert_nil(value, message)
    if value ~= nil then fail(message or ("expected nil, got " .. tostring(value))) end
end

function Harness.assert_not_nil(value, message)
    if value == nil then fail(message or "expected non-nil") end
end

function Harness.assert_equal(expected, actual, message)
    if expected ~= actual then
        fail(message or string.format("expected %s, got %s",
            tostring(expected), tostring(actual)))
    end
end

function Harness.assert_deep_equal(expected, actual, message)
    local function eq(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b end
        for k, v in pairs(a) do
            if not eq(v, b[k]) then return false end
        end
        for k in pairs(b) do
            if a[k] == nil then return false end
        end
        return true
    end
    if not eq(expected, actual) then
        fail(message or "tables differ")
    end
end

function Harness.assert_error(fn, message)
    local ok = pcall(fn)
    if ok then fail(message or "expected an error, but call succeeded") end
end

function Harness.run()
    for _, case in ipairs(suites) do
        local ok, err = pcall(case.fn)
        if ok then
            passed = passed + 1
        else
            failed = failed + 1
            failures[#failures + 1] = { name = case.name, err = tostring(err) }
        end
    end
end

function Harness.report()
    io.write(string.format("\n%d passed, %d failed, %d total\n",
        passed, failed, passed + failed))
    for _, f in ipairs(failures) do
        io.write("FAIL: ", f.name, "\n  ", f.err, "\n")
    end
    return failed
end

-- Install the DSL as globals for the duration of a spec file.
function Harness.install_globals()
    _G.describe = Harness.describe
    _G.it = Harness.it
    _G.assert_true = Harness.assert_true
    _G.assert_false = Harness.assert_false
    _G.assert_nil = Harness.assert_nil
    _G.assert_not_nil = Harness.assert_not_nil
    _G.assert_equal = Harness.assert_equal
    _G.assert_deep_equal = Harness.assert_deep_equal
    _G.assert_error = Harness.assert_error
end

return Harness
