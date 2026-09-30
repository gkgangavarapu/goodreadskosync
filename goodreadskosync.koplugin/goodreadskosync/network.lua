--[[--
Network layer.

Thin, normalized wrapper over KOReader's bundled LuaSocket. Provider modules
use this; UI code never issues HTTP directly. Response bodies are never logged.

@module koplugin.goodreads.network
--]]

local Constants = require("goodreadskosync.constants")
local Logging = require("goodreadskosync.logging")

local Network = {}

local function load(name)
    local ok, module = pcall(require, name)
    if ok then return module end
    return nil
end

local DEFAULT_TIMEOUT = 30

function Network.normalizeStatus(status)
    status = tonumber(status)
    if not status then return Constants.ERROR.NETWORK_ERROR end
    if status == 200 or status == 201 or status == 202 or status == 204 then
        return nil
    elseif status == 401 then
        return Constants.ERROR.AUTH_REQUIRED
    elseif status == 403 then
        return Constants.ERROR.AUTH_REQUIRED
    elseif status == 404 then
        return Constants.ERROR.NOT_FOUND
    elseif status == 409 then
        return Constants.ERROR.CONFLICT
    elseif status == 422 then
        return Constants.ERROR.INVALID_REQUEST
    elseif status == 429 then
        return Constants.ERROR.RATE_LIMITED
    elseif status >= 500 then
        return Constants.ERROR.SERVER_ERROR
    end
    return Constants.ERROR.INVALID_RESPONSE
end

local function request(method, url, opts)
    opts = opts or {}
    local http = load("socket.http")
    local ltn12 = load("ltn12")
    if not http or not ltn12 then
        return nil, Constants.ERROR.PROVIDER_UNAVAILABLE, nil
    end

    local response = {}
    local request_table = {
        url = url,
        method = method,
        headers = opts.headers or {},
        sink = ltn12.sink.table(response),
        redirect = true,
    }
    if opts.body then
        request_table.source = ltn12.source.string(opts.body)
    end
    if opts.timeout then
        request_table.timeout = opts.timeout
    end

    local previous_timeout = http.TIMEOUT
    http.TIMEOUT = opts.timeout or DEFAULT_TIMEOUT

    local ok, status = pcall(http.request, request_table)
    http.TIMEOUT = previous_timeout

    if not ok then
        Logging.warn("network: request failed", method, Logging.redact(url))
        return nil, Constants.ERROR.NETWORK_ERROR, nil
    end

    local err = Network.normalizeStatus(status)
    local body = table.concat(response)
    if err then
        Logging.warn("network: HTTP status", tostring(status), "for",
            Logging.redact(url))
        return nil, err, status
    end
    return body, nil, status
end

function Network.get(url, opts)
    return request("GET", url, opts)
end

function Network.post(url, body, opts)
    opts = opts or {}
    opts.body = body
    if not opts.headers then
        opts.headers = { ["Content-Type"] = "application/json" }
    end
    return request("POST", url, opts)
end

-- Decode a JSON body. Returns table or nil, error.
function Network.decodeJson(body)
    if type(body) ~= "string" or body == "" then
        return nil, Constants.ERROR.INVALID_RESPONSE
    end
    local json = load("json")
    if not json then return nil, Constants.ERROR.PROVIDER_UNAVAILABLE end
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= "table" then
        return nil, Constants.ERROR.INVALID_RESPONSE
    end
    return decoded
end

function Network.encodeJson(value)
    local json = load("json")
    if not json then return nil, Constants.ERROR.PROVIDER_UNAVAILABLE end
    local ok, encoded = pcall(json.encode, value)
    if not ok then return nil, Constants.ERROR.INVALID_RESPONSE end
    return encoded
end

return Network
