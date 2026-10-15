--[[--
Secret-at-rest helper (inspired by ShelfSync).

Uses AES-256-CBC through the libcrypto that KOReader already links, with the
key kept in a separate settings file. This stops secrets from sitting in
cleartext in a settings file that might be shared for support, but it is NOT
protection against someone with full filesystem access (KOReader has no OS
keystore). Every function degrades to nil when libcrypto is unavailable, so
callers can fall back to plaintext - which is what happens on Android, where no
reachable library exports the OpenSSL symbols (the system libcrypto is outside
the app's linker namespace). Degrading must never raise: a throw here used to
abort the login after Goodreads had already accepted it.

@module koplugin.goodreads.crypto_util
--]]

local CryptoUtil = {}

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then ffi = nil end

local KEYRING_FILENAME = "goodreadskosync_keyring.lua"
local KEY_SETTING = "session_aes_key"

local libcrypto -- nil = unresolved, false = failed
local cdef_done = false

local function ensure_cdef()
    if cdef_done then return end
    cdef_done = true
    ffi.cdef([[
        typedef struct engine_st ENGINE;
        typedef struct evp_cipher_st EVP_CIPHER;
        typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
        EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
        void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *);
        int EVP_EncryptInit_ex(EVP_CIPHER_CTX *, const EVP_CIPHER *, ENGINE *, const unsigned char *, const unsigned char *);
        int EVP_EncryptUpdate(EVP_CIPHER_CTX *, unsigned char *, int *, const unsigned char *, int);
        int EVP_EncryptFinal_ex(EVP_CIPHER_CTX *, unsigned char *, int *);
        int EVP_DecryptInit_ex(EVP_CIPHER_CTX *, const EVP_CIPHER *, ENGINE *, const unsigned char *, const unsigned char *);
        int EVP_DecryptUpdate(EVP_CIPHER_CTX *, unsigned char *, int *, const unsigned char *, int);
        int EVP_DecryptFinal_ex(EVP_CIPHER_CTX *, unsigned char *, int *);
        const EVP_CIPHER *EVP_aes_256_cbc(void);
        int RAND_bytes(unsigned char *, int);
    ]])
end

-- A library handle is only usable when the symbols we declared actually resolve.
-- It can load and still export none of them: on Android nothing reachable
-- exports RAND_bytes/EVP_* (the system libcrypto is outside the app's linker
-- namespace), and every call would raise. Probing once turns that into "no
-- crypto" instead of an error escaping the login.
local function usable(lib)
    if not lib then return false end
    local ok = pcall(function() return lib.EVP_aes_256_cbc() end)
    return ok
end

local function get_libcrypto()
    if libcrypto ~= nil then return libcrypto or nil end
    if not ffi then
        libcrypto = false
        return nil
    end
    local ok, result = pcall(function()
        ensure_cdef()
        return ffi.loadlib("crypto", "57")
    end)
    libcrypto = (ok and usable(result)) and result or false
    return libcrypto or nil
end

local function random_bytes(lib, n)
    local buf = ffi.new("unsigned char[?]", n)
    local ok, rc = pcall(function() return lib.RAND_bytes(buf, n) end)
    if not ok or rc ~= 1 then return nil end
    return ffi.string(buf, n)
end

local function to_hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function from_hex(s)
    if type(s) ~= "string" or not s:match("^%x*$") or #s % 2 ~= 0 then return nil end
    return (s:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end

function CryptoUtil.aesEncrypt(plaintext, key)
    local lib = get_libcrypto()
    if not lib or not plaintext or plaintext == "" or not key or #key ~= 32 then
        return nil
    end
    local iv = random_bytes(lib, 16)
    if not iv then return nil end

    local ctx = lib.EVP_CIPHER_CTX_new()
    if ctx == nil then return nil end

    local ok = lib.EVP_EncryptInit_ex(ctx, lib.EVP_aes_256_cbc(), nil, key, iv) == 1
    local output, output_len
    if ok then
        output = ffi.new("unsigned char[?]", #plaintext + 16)
        local len1 = ffi.new("int[1]")
        ok = lib.EVP_EncryptUpdate(ctx, output, len1, plaintext, #plaintext) == 1
        if ok then
            local len2 = ffi.new("int[1]")
            ok = lib.EVP_EncryptFinal_ex(ctx, output + len1[0], len2) == 1
            if ok then output_len = len1[0] + len2[0] end
        end
    end
    lib.EVP_CIPHER_CTX_free(ctx)
    if not ok then return nil end
    return to_hex(iv .. ffi.string(output, output_len))
end

function CryptoUtil.aesDecrypt(blob_hex, key)
    local lib = get_libcrypto()
    if not lib or not blob_hex or blob_hex == "" or not key or #key ~= 32 then
        return nil
    end
    local raw = from_hex(blob_hex)
    if not raw or #raw <= 16 then return nil end
    local iv = raw:sub(1, 16)
    local ciphertext = raw:sub(17)

    local ctx = lib.EVP_CIPHER_CTX_new()
    if ctx == nil then return nil end

    local ok = lib.EVP_DecryptInit_ex(ctx, lib.EVP_aes_256_cbc(), nil, key, iv) == 1
    local output, output_len
    if ok then
        output = ffi.new("unsigned char[?]", #ciphertext + 16)
        local len1 = ffi.new("int[1]")
        ok = lib.EVP_DecryptUpdate(ctx, output, len1, ciphertext, #ciphertext) == 1
        if ok then
            local len2 = ffi.new("int[1]")
            ok = lib.EVP_DecryptFinal_ex(ctx, output + len1[0], len2) == 1
            if ok then output_len = len1[0] + len2[0] end
        end
    end
    lib.EVP_CIPHER_CTX_free(ctx)
    if not ok then return nil end
    return ffi.string(output, output_len)
end

local keyring

local function get_keyring()
    if keyring then return keyring end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not (ok_ds and ok_ls) then return nil end
    local ok, result = pcall(function()
        return LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. KEYRING_FILENAME)
    end)
    if not ok then return nil end
    keyring = result
    return keyring
end

function CryptoUtil.getOrCreateKey()
    local lib = get_libcrypto()
    if not lib then return nil end
    local kr = get_keyring()
    if not kr then return nil end

    local hex_key = kr:readSetting(KEY_SETTING)
    if hex_key and #hex_key == 64 then
        local key = from_hex(hex_key)
        if key then return key end
    end

    local key = random_bytes(lib, 32)
    if not key then return nil end
    kr:saveSetting(KEY_SETTING, to_hex(key))
    kr:flush()
    return key
end

function CryptoUtil.encryptSecret(plaintext)
    local key = CryptoUtil.getOrCreateKey()
    if not key then return nil end
    -- Belt and braces: a symbol that resolves in the probe can still fail here,
    -- and nothing in this module may raise - a failed encryption means "store
    -- it in plaintext", never "the login could not be saved".
    local ok, blob = pcall(CryptoUtil.aesEncrypt, plaintext, key)
    if not ok or type(blob) ~= "string" then return nil end
    return blob
end

function CryptoUtil.decryptSecret(blob_hex)
    local key = CryptoUtil.getOrCreateKey()
    if not key then return nil end
    local ok, plain = pcall(CryptoUtil.aesDecrypt, blob_hex, key)
    if not ok or type(plain) ~= "string" then return nil end
    return plain
end

-- "Encrypt if possible, otherwise plaintext" convenience: returns a value and
-- whether it is encrypted.
function CryptoUtil.protect(plaintext)
    local blob = CryptoUtil.encryptSecret(plaintext)
    if blob then return blob, true end
    return plaintext, false
end

function CryptoUtil.unprotect(value, encrypted)
    if not encrypted then return value end
    return CryptoUtil.decryptSecret(value) or ""
end

return CryptoUtil
