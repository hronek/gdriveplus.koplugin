--- Reading progress push/pull.
---
--- Remote layout: KOReader_Sync/progress/<book file name>.json
---   { version, book={file, partial_md5}, progress, percentage, pages,
---     timestamp, device, device_id }
--- `progress` is a page number (PDF…) or an xpointer (EPUB…). Another client
--- that cannot produce an xpointer may omit it; `percentage` is then used.

local Event = require("ui/event")
local gjson = require("gdriveplus_gjson")
local logger = require("logger")

local M = {}

function M.get_current(ui)
    if not ui or not ui.document then return nil end
    local progress_val, percent_val
    if ui.paging then
        progress_val = ui.paging:getLastProgress()
        percent_val = ui.paging:getLastPercent()
    elseif ui.rolling then
        progress_val = ui.rolling:getLastProgress()
        percent_val = ui.rolling:getLastPercent()
    end
    if progress_val == nil then return nil end
    local pages
    local ok, n = pcall(ui.document.getPageCount, ui.document)
    if ok and type(n) == "number" then pages = n end
    return { progress = progress_val, percentage = percent_val or 0, pages = pages }
end

local function go_to(ui, remote)
    local pct = type(remote.percentage) == "number" and remote.percentage or nil
    if ui.paging then
        local page = tonumber(remote.progress)
        if page then
            ui:handleEvent(Event:new("GotoPage", page))
            return true
        end
    elseif type(remote.progress) == "string" and remote.progress ~= "" then
        local doc = ui.document
        local valid = true
        if type(doc.isXPointerInDocument) == "function" then
            local ok, res = pcall(doc.isXPointerInDocument, doc, remote.progress)
            valid = ok and res
        end
        if valid then
            ui:handleEvent(Event:new("GotoXPointer", remote.progress))
            return true
        end
    end
    if pct then
        ui:handleEvent(Event:new("GotoPercent", pct * 100))
        return true
    end
    return false
end

local function locate(network, token, ctx)
    if ctx.cache.prog_id then return { id = ctx.cache.prog_id } end
    local file, err = network.findFile(token, ctx.remote_name, { parent_id = ctx.folder_id })
    if err then return nil, err end
    if file then return file end
    file, err = network.findByProperty(token, "partial_md5", ctx.book.partial_md5, ctx.folder_id)
    if err then return nil, err end
    return file
end

--- The content of a progress file (`version` is the progress file format).
--- @param pos {progress, percentage, pages}
--- @param ts  when the position was read (Unix time)
function M.record(book, pos, ts, device, device_id)
    return {
        version = 2,
        book = { file = book.file, partial_md5 = book.partial_md5 },
        progress = pos.progress,
        percentage = pos.percentage,
        pages = pos.pages,
        timestamp = ts,
        device = device,
        device_id = device_id,
    }
end

--- @param ctx {ui, book, remote_name, folder_id, cache, device, device_id}
--- @return true — or false, error
function M.push(network, token, ctx)
    local cur = M.get_current(ctx.ui)
    if not cur then return false, "no reading position" end
    local ok, err = M.push_position(network, token, ctx, cur, os.time())
    if not ok then return false, err end
    logger.dbg("GDrivePlus: pushed progress", cur.percentage)
    return true
end

--- Upload a given position (also for a book that is not open).
--- @param ctx {book, remote_name, folder_id, cache, device, device_id}
--- @return true, the uploaded JSON — or false, error
function M.push_position(network, token, ctx, pos, ts)
    local body = gjson.encode(M.record(ctx.book, pos, ts, ctx.device, ctx.device_id))

    local function put(id)
        return network.upload(token, {
            id = id,
            name = ctx.remote_name,
            parent_id = ctx.folder_id,
            app_properties = { partial_md5 = ctx.book.partial_md5 },
            content = body,
            mime = "application/json",
        })
    end

    local id, err
    if ctx.cache.prog_id then
        id, err = put(ctx.cache.prog_id)
        if not id then ctx.cache.prog_id = nil end -- stale id: fall through to a lookup
    end
    if not id then
        local file, lerr = locate(network, token, ctx)
        if lerr then return false, lerr end
        id, err = put(file and file.id or nil)
    end
    if not id then return false, "upload: " .. tostring(err) end
    ctx.cache.prog_id = id
    ctx.cache.progress_ts = ts
    return true, body
end

--- Download and decode a progress file.
--- @return record — or nil, error, HTTP code
function M.fetch(network, token, file_id)
    local content, err, code = network.download(token, file_id)
    if not content then return nil, "download: " .. tostring(err), code end
    local remote = gjson.decode(content)
    if type(remote) ~= "table" then return nil, "remote progress is not valid JSON" end
    return remote
end

--- The remote position in the form this kind of book keeps it: a page number
--- for paging books, an xpointer for reflowable ones; nil when the record has
--- only a percentage (or the other kind of position).
function M.usable_progress(remote, paging)
    if type(remote) ~= "table" then return nil end
    if paging then
        local page = tonumber(remote.progress)
        if page and page >= 1 then return math.floor(page) end
    elseif type(remote.progress) == "string" and remote.progress ~= "" and not tonumber(remote.progress) then
        return remote.progress
    end
    return nil
end

--- Same place in the book? Positions when both have one, else percentages.
function M.same_position(a, b)
    if a.progress ~= nil and b.progress ~= nil then return a.progress == b.progress end
    local pa, pb = tonumber(a.percentage), tonumber(b.percentage)
    return pa ~= nil and pb ~= nil and math.abs(pa - pb) < 0.0005
end

--- What to do with a book that is not open (library sync): the position here
--- against the one on Drive. The newer one wins; clocks matter only when the
--- positions differ.
--- @param here     {progress, percentage} from the book's metadata, or nil
--- @param here_ts  when the book was last read here (0/nil when unknown)
--- @param remote   the progress record on Drive, or nil
--- @param opts     {device_id, only_ahead}
--- @return "push" | "apply" | "behind" | "same"
function M.decide(here, here_ts, remote, opts)
    here_ts = tonumber(here_ts) or 0
    if type(remote) ~= "table" then return here and "push" or "same" end
    if not here then return "apply" end -- also this device's own record: the metadata was reset
    if M.same_position(here, remote) then return "same" end
    local remote_ts = tonumber(remote.timestamp) or 0
    if here_ts > remote_ts then return "push" end
    if remote_ts == here_ts then return "same" end
    if remote.device_id ~= nil and remote.device_id == opts.device_id then return "same" end
    if opts.only_ahead then
        local a, b = tonumber(remote.percentage), tonumber(here.percentage)
        if a and b and a <= b + 0.001 then return "behind" end
    end
    return "apply"
end

--- Jump to a pulled position (directly, or after the user agreed to it).
--- @return true when the position could be used in this book
function M.apply(ctx, remote)
    if go_to(ctx.ui, remote) then
        ctx.cache.progress_ts = os.time()
        return true
    end
    return false
end

--- Page, page count, percentage and chapter of a position, for showing it.
--- @param pos {progress, percentage}
--- @return {page, pages, percent, chapter, approx}; any field may be missing
function M.describe(ui, pos)
    local doc = ui and ui.document
    if not doc or type(pos) ~= "table" then return {} end
    local info = {}
    local ok, n = pcall(doc.getPageCount, doc)
    if ok and type(n) == "number" then info.pages = n end
    if ui.paging then
        info.page = tonumber(pos.progress)
    elseif type(pos.progress) == "string" and pos.progress ~= ""
        and type(doc.getPageFromXPointer) == "function" then
        local ok2, p = pcall(doc.getPageFromXPointer, doc, pos.progress)
        if ok2 and type(p) == "number" then info.page = p end
    end
    local pct = tonumber(pos.percentage)
    if pct then
        info.percent = math.floor(pct * 100 + 0.5)
        if not info.page and info.pages then
            -- a writer without page or xpointer (e.g. the web reader on some formats)
            info.page = math.max(1, math.floor(pct * info.pages + 0.5))
            info.approx = true
        end
    end
    if info.page and ui.toc and type(ui.toc.getTocTitleByPage) == "function" then
        local ok3, title = pcall(ui.toc.getTocTitleByPage, ui.toc, info.page)
        if ok3 and type(title) == "string" and title ~= "" then info.chapter = title end
    end
    return info
end

--- Is `remote` further on in the book than `cur`? Unknown counts as yes, so a
--- position is never hidden just because it cannot be compared.
function M.is_ahead(ui, cur, remote)
    local here, there = M.describe(ui, cur), M.describe(ui, remote)
    if here.page and there.page and not here.approx and not there.approx then
        return there.page > here.page
    end
    local a, b = tonumber(remote.percentage), cur and tonumber(cur.percentage)
    if not a or not b then return true end
    return a > b + 0.001
end

--- @param force  jump even when the remote position is older / from this device
--- Without `force`, a position is offered only when it comes from another device,
--- was not declined before, and (each can be switched off):
---   ctx.only_newer ~= false: was saved after this device last read the book
---     (the later of ctx.cache.progress_ts and ctx.read_ts, the last page turn);
---   ctx.only_ahead: is further on in the book than the position here.
--- When `ctx.confirm` is set (and not `force`), such a position is not applied
--- but returned as "newer", remote, so the caller can ask first (then `M.apply`).
--- @return status ("moved" | "newer" | "same" | "older" | "behind" | "none") — or nil, error
function M.pull(network, token, ctx, force)
    local file, err = locate(network, token, ctx)
    if err then return nil, err end
    if not file then return "none" end

    local content, derr, code = network.download(token, file.id)
    if not content and code == 404 and ctx.cache.prog_id then
        ctx.cache.prog_id = nil
        return M.pull(network, token, ctx, force)
    end
    if not content then return nil, "download: " .. tostring(derr) end
    ctx.cache.prog_id = file.id

    local remote = gjson.decode(content)
    if type(remote) ~= "table" then return nil, "remote progress is not valid JSON" end

    local cur = M.get_current(ctx.ui)
    if cur and remote.progress ~= nil and remote.progress == cur.progress then return "same" end

    if not force then
        if remote.device_id ~= nil and remote.device_id == ctx.device_id then return "same" end
        local remote_ts = tonumber(remote.timestamp) or 0
        if remote_ts == tonumber(ctx.cache.declined_ts) then return "older" end -- "Stay here" before
        if ctx.only_newer ~= false then
            local read_here = math.max(tonumber(ctx.cache.progress_ts) or 0, tonumber(ctx.read_ts) or 0)
            if remote_ts <= read_here then return "older" end
        end
        if ctx.only_ahead and not M.is_ahead(ctx.ui, cur, remote) then return "behind" end
    end

    if ctx.confirm and not force then return "newer", remote end
    if M.apply(ctx, remote) then return "moved", remote end
    return nil, "remote position cannot be used"
end

return M
