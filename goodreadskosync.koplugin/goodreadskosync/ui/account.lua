--[[--
Account UI.

@module koplugin.goodreads.ui.account
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local Widgets = require("goodreadskosync.ui.widgets")

local Account = {}

-- status = { account, state, user_id, has_saved }
-- handlers = { login, logout, test, forget_credentials }
function Account.show(status, handlers)
    handlers = handlers or {}
    local dialog
    local lines = {
        _("Goodreads Sync"),
        "",
    }
    if status.account and (status.account.username or status.account.id) then
        lines[#lines + 1] = string.format("%s: %s", _("Signed in as"),
            status.account.username or status.account.id)
    elseif status.state == "expired" then
        lines[#lines + 1] = _("Your session expired. Please sign in again.")
    elseif status.state == "blocked" then
        lines[#lines + 1] = _("Goodreads asked for a sign-in check. Please sign in again.")
    else
        lines[#lines + 1] = _("Not signed in.")
    end
    if status.has_saved then
        lines[#lines + 1] = _("Password is saved on this device.")
    end

    local buttons = {}
    if status.account then
        buttons[#buttons + 1] = { {
            text = _("Test connection"),
            callback = function()
                UIManager:close(dialog)
                if handlers.test then handlers.test() end
            end,
        } }
        buttons[#buttons + 1] = { {
            text = _("Log out"),
            callback = function()
                UIManager:close(dialog)
                if handlers.logout then handlers.logout() end
            end,
        } }
    else
        buttons[#buttons + 1] = { {
            text = _("Sign in to Goodreads"),
            callback = function()
                UIManager:close(dialog)
                if handlers.login then handlers.login() end
            end,
        } }
    end
    if status.has_saved and handlers.forget_credentials then
        buttons[#buttons + 1] = { {
            text = _("Forget saved password"),
            callback = function()
                UIManager:close(dialog)
                handlers.forget_credentials()
            end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("Close"),
        callback = function() UIManager:close(dialog) end,
    } }

    dialog = ButtonDialog:new{
        title = table.concat(lines, "\n"),
        buttons = buttons,
        width_factor = 0.9,
    }
    UIManager:show(dialog)
end

function Account.notify(text)
    Widgets.message(text, 4)
end

return Account
