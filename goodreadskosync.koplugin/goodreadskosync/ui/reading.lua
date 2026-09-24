--[[--
Reading Challenge / reading-stats UI.

Mixed into the plugin as methods (`self` is the plugin instance).

@module koplugin.goodreads.ui.reading
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local Reading = require("goodreadskosync.reading")
local UIManager = require("ui/uimanager")
local Widgets = require("goodreadskosync.ui.widgets")
local _ = require("gettext")

local ReadingUI = {}

local function challengeText(data)
    data = data or {}
    local lines = { _("Reading Challenge"), "" }
    if (data.goal or 0) > 0 then
        lines[#lines + 1] = string.format(_("%d of %d books read (%d%%)"),
            data.books_read or 0, data.goal, data.percent or 0)
    else
        lines[#lines + 1] = _("No reading goal set for this year.")
    end
    if data.days_remaining then
        lines[#lines + 1] = string.format(_("%d days left"), data.days_remaining)
    end
    if data.pace_label == "ahead" and data.pace_diff then
        local n = math.max(1, math.floor(math.abs(data.pace_diff) + 0.5))
        lines[#lines + 1] = string.format(_("%d books ahead of schedule"), n)
    elseif data.pace_label == "behind" and data.pace_diff then
        local n = math.max(1, math.floor(math.abs(data.pace_diff) + 0.5))
        lines[#lines + 1] = string.format(_("%d books behind schedule"), n)
    elseif data.pace_label == "on_track" then
        lines[#lines + 1] = _("On track")
    end
    return table.concat(lines, "\n")
end

-- Fetch and show this year's Reading Challenge progress.
function ReadingUI:showReadingChallenge()
    local provider = self:getProvider()
    if not provider then
        Widgets.message(_("No provider available."))
        return
    end
    self:runWhenOnline(function()
        self:runAsync(function()
            local completed, data = self:runInBackground(_("Loading reading challenge…"),
                function() return provider:get_reading_challenge() end)
            if completed == false then return end
            if type(data) ~= "table" then
                Widgets.message(_("Couldn't load the reading challenge."))
                return
            end
            data = Reading.enrich(data)
            self:setSetting("reading_goal_cache", data.goal)

            local dialog
            local buttons = {
                {
                    {
                        text = _("Change goal"),
                        callback = function()
                            UIManager:close(dialog)
                            self:promptReadingGoal(data.goal)
                        end,
                    },
                    {
                        text = _("Refresh"),
                        callback = function()
                            UIManager:close(dialog)
                            self:showReadingChallenge()
                        end,
                    },
                },
                { {
                    text = _("Close"),
                    callback = function() UIManager:close(dialog) end,
                } },
            }
            dialog = ButtonDialog:new{
                title = challengeText(data),
                buttons = buttons,
                width_factor = 0.9,
            }
            UIManager:show(dialog)
        end)
    end)
end

-- Prompt for the annual goal and save it.
function ReadingUI:promptReadingGoal(current)
    if current == nil then current = self:getSetting("reading_goal_cache") end
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Reading Challenge goal"),
        description = _("How many books do you want to read this year?"),
        input = current and tostring(current) or "",
        input_type = "number",
        buttons = { {
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                callback = function()
                    local value = tonumber(dialog:getInputText())
                    UIManager:close(dialog)
                    self:setReadingGoal(value)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ReadingUI:setReadingGoal(goal)
    if not goal or goal < 1 or goal ~= math.floor(goal) then
        Widgets.message(_("Enter a whole number of books."))
        return
    end
    local provider = self:getProvider()
    if not provider then
        Widgets.message(_("No provider available."))
        return
    end
    self:runWhenOnline(function()
        self:runAsync(function()
            local completed, ok = self:runInBackground(_("Saving goal…"),
                function() return provider:set_reading_goal(goal) end)
            if completed == false then return end
            if ok == true then
                self:setSetting("reading_goal_cache", goal)
                Widgets.notify(string.format(_("Reading goal set to %d"), goal))
            else
                Widgets.message(_("Couldn't save the reading goal."))
            end
        end)
    end)
end

-- Show per-year book counts from the reading-stats page.
function ReadingUI:showReadingStats()
    local provider = self:getProvider()
    if not provider then
        Widgets.message(_("No provider available."))
        return
    end
    self:runWhenOnline(function()
        self:runAsync(function()
            local completed, years = self:runInBackground(_("Loading reading stats…"),
                function() return provider:get_reading_stats() end)
            if completed == false then return end
            if type(years) ~= "table" or #years == 0 then
                Widgets.message(_("No reading stats yet."))
                return
            end
            local lines = { _("Reading stats"), "" }
            local total = 0
            for i = 1, math.min(#years, 12) do
                local y = years[i]
                total = total + (y.books or 0)
                lines[#lines + 1] = string.format(_("%d: %d books"), y.year, y.books or 0)
            end
            lines[#lines + 1] = ""
            lines[#lines + 1] = string.format(_("Total: %d books"), total)
            UIManager:show(InfoMessage:new{
                text = table.concat(lines, "\n"),
                timeout = 20,
            })
        end)
    end)
end

return ReadingUI
