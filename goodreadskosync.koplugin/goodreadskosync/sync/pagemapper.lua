--[[--
Page mapper (inspired by ShelfSync).

Maps local page numbers to the linked Goodreads edition's page numbers using
KOReader's page labels, so progress can be sent as a page number when the
edition paginates differently.

@module koplugin.goodreads.sync.pagemapper
--]]

local TableUtil = require("goodreadskosync.table_util")

local PageMapper = {}
PageMapper.__index = PageMapper

function PageMapper:new(o)
    o = o or {}
    o.state = o.state or {}
    return setmetatable(o, self)
end

function PageMapper:usePageMap()
    return self.ui and self.ui.pagemap and self.ui.pagemap:wantsPageLabels()
        and not self.ui.pagemap.chars_per_synthetic_page
end

function PageMapper:checkIgnorePagemap()
    local current_page_labels = self:usePageMap()
    if current_page_labels == self.use_page_map then return end
    self.use_page_map = current_page_labels
    if current_page_labels then
        self:cachePageMap()
    else
        self.state.page_map = nil
    end
end

local function toInteger(number)
    local as_number = tonumber(number)
    if as_number then return math.floor(as_number) end
end

function PageMapper:cachePageMap()
    if not self:usePageMap() then return end
    local page_map = self.ui.document:getPageMap()
    if type(page_map) ~= "table" then return end

    local lookup = {}
    local page_label = 1
    local last_page_label = 1
    local last_page = 1
    local max_page_label = 1

    for _, v in ipairs(page_map) do
        page_label = toInteger(v.label) or page_label
        for i = last_page, v.page, 1 do
            lookup[i] = last_page_label
        end
        lookup[v.page] = page_label
        last_page = v.page
        max_page_label = page_label > max_page_label and page_label or max_page_label
        last_page_label = page_label
    end

    self.state.page_map_range = {
        real_page = max_page_label,
        last_page = last_page,
    }
    self.state.page_map = lookup
end

function PageMapper:getUnmappedPage(remote_page, document_pages, remote_pages)
    self:checkIgnorePagemap()
    local target_page = remote_page
    if self.state.page_map and remote_pages and self.state.page_map_range
        and self.state.page_map_range.real_page then
        target_page = math.floor((remote_page / remote_pages)
            * self.state.page_map_range.real_page + 0.5)
    end
    local document_page = self.state.page_map
        and TableUtil.binSearch(self.state.page_map, target_page)
    if not document_page then
        document_page = math.floor((remote_page / remote_pages) * document_pages + 0.5)
    end
    return document_page
end

function PageMapper:getMappedPage(raw_page, document_pages, remote_pages)
    self:checkIgnorePagemap()
    if self.state.page_map then
        local mapped_page = self.state.page_map[raw_page]
        if mapped_page then
            if remote_pages and self.state.page_map_range
                and self.state.page_map_range.real_page then
                return math.floor((mapped_page / self.state.page_map_range.real_page)
                    * remote_pages + 0.5)
            end
            return mapped_page
        elseif self.state.page_map_range
            and raw_page > self.state.page_map_range.last_page then
            return remote_pages or self.state.page_map_range.real_page
        end
    end
    if remote_pages and document_pages then
        return math.floor((raw_page / document_pages) * remote_pages + 0.5)
    end
    return raw_page
end

-- Returns decimal_percent (0..1), mapped_page (or nil).
function PageMapper:getRemotePagePercent(raw_page, document_pages, remote_pages)
    self:checkIgnorePagemap()

    local local_percent = nil
    local mapped_page = nil

    if self.state.page_map then
        mapped_page = self.state.page_map[raw_page]
        if not mapped_page and self.state.page_map_range
            and self.state.page_map_range.last_page
            and raw_page > self.state.page_map_range.last_page then
            return 1, remote_pages or self.state.page_map_range.real_page
        end
        if mapped_page then
            local pagemap_total = (self.state.page_map_range
                and self.state.page_map_range.real_page) or 1
            if remote_pages then
                local scaled_page = math.floor((mapped_page / pagemap_total)
                    * remote_pages + 0.5)
                return math.min(1.0, scaled_page / remote_pages), scaled_page
            else
                local_percent = mapped_page / pagemap_total
            end
        end
    end

    if not local_percent and document_pages and document_pages > 0 then
        local_percent = raw_page / document_pages
    end

    if local_percent then
        local total_pages = remote_pages or document_pages
        local remote_page = math.floor(local_percent * total_pages + 0.5)
        return remote_page / total_pages, mapped_page or remote_page
    end

    return 0, 0
end

return PageMapper
