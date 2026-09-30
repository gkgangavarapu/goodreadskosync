--[[--
Optional saved credentials (testing aid).

Storing a password on-device is not the default and is not secure: KOReader has
no OS keystore, so the value is written in plain text under the plugin settings
directory. This module exists so a tester can opt in and avoid re-typing the
password on every session expiry. It is never logged and never included in
diagnostics.

@module koplugin.goodreads.auth.credentials
--]]

local Constants = require("goodreadskosync.constants")
local CryptoUtil = require("goodreadskosync.crypto_util")
local Storage = require("goodreadskosync.storage")

local Credentials = {}

local function store()
    return Storage.open(Constants.STORAGE.CREDENTIALS)
end

function Credentials.save(email, password)
    if type(email) ~= "string" or email == ""
        or type(password) ~= "string" or password == "" then
        return false
    end
    local s = store()
    local blob, encrypted = CryptoUtil.protect(password)
    s:set("email", email)
    s:set("password", blob)
    s:set("password_encrypted", encrypted and true or false)
    s:set("saved_at", os.time())
    return s:flush()
end

function Credentials.load()
    local s = store()
    local email = s:get("email")
    local password = s:get("password")
    if type(email) ~= "string" or email == ""
        or type(password) ~= "string" or password == "" then
        return nil
    end
    password = CryptoUtil.unprotect(password, s:get("password_encrypted"))
    if type(password) ~= "string" or password == "" then
        return nil
    end
    return { email = email, password = password, saved_at = s:get("saved_at") }
end

function Credentials.has()
    return Credentials.load() ~= nil
end

function Credentials.clear()
    local s = store()
    s:delete("email")
    s:delete("password")
    s:delete("password_encrypted")
    s:delete("saved_at")
    return s:flush()
end

return Credentials
