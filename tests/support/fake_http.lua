--[[--
Scripted HTTP transport for tests.

Returns a transport function plus the list of captured requests, so specs can
assert on the exact request shape as well as drive responses.

@module tests.support.fake_http
--]]

local FakeHttp = {}

-- responses: array of { ok (default true), status, headers, body }.
-- The last response is repeated once the script runs out.
function FakeHttp.scripted(responses)
    local calls = {}
    local index = 0
    local transport = function(req)
        calls[#calls + 1] = req
        index = index + 1
        local response = responses[index] or responses[#responses] or {}
        if response.ok == false then
            return false, nil, nil, nil
        end
        return true, response.status or 200, response.headers or {}, response.body or ""
    end
    return transport, calls
end

return FakeHttp
