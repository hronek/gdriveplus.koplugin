--- Library sync (gdriveplus_library.lua) against an in-memory Drive and fake
--- KOReader metadata, history and file system.
---     luajit tests/test_library.lua

package.path = "./?.lua;" .. package.path
dofile("tests/foreign_modules.lua")

-- KOReader stubs -------------------------------------------------------------
package.preload["logger"] = function()
    local function nop() end
    return { warn = nop, dbg = nop, info = nop, err = nop }
end
package.preload["ui/event"] = function()
    return { new = function(_, name, arg) return { name = name, arg = arg } end }
end

local gjson = require("gdriveplus_gjson")
local annotations = require("gdriveplus_annotations")
local utils = require("gdriveplus_utils")
local library = require("gdriveplus_library")
local new_drive = dofile("tests/fake_drive.lua")

local passed, failed = 0, 0
local function check(cond, name)
    if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end
local function eq(a, b, name)
    check(a == b, name .. "  (got " .. tostring(a) .. ", expected " .. tostring(b) .. ")")
end

-- snapshots (<sdr>/gdriveplus.json) and the index live in memory
local files = {}
utils.write_file = function(path, content) files[path] = content; return true end
utils.read_json = function(path)
    local c = files[path]
    if not c then return nil end
    local d = gjson.decode(c)
    return type(d) == "table" and d or nil
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copy(x) end
    return t
end

-- Fake device: metadata files, history, clock ------------------------------------
local function new_device(id)
    local dev = { meta = {}, mtime = {}, hist = {}, clock = 1000, changed = {}, dom = { 20240114, 20180528 } }
    dev.docs = {
        open = function(path)
            local data = copy(dev.meta[path]) or {}
            local ds = { data = data, path = path }
            function ds:readSetting(k) return self.data[k] end
            function ds:saveSetting(k, v) self.data[k] = v end
            return ds, dev.meta[path] ~= nil
        end,
        flush = function(ds)
            dev.meta[ds.path] = copy(ds.data)
            dev.clock = dev.clock + 1
            dev.mtime[ds.path] = dev.clock
        end,
        sidecar_dir = function(path) return (path:gsub("%.%w+$", "")) .. ".sdr" end,
        sidecar_mtime = function(path) return dev.mtime[path] end,
        paging = function(path)
            if path:match("%.pdf$") then return true elseif path:match("%.epub$") then return false end
        end,
        partial_md5 = function(path) return "md5:" .. path end,
        dom_versions = function() return dev.dom[1], dev.dom[2] end,
        history_time = function(path) return dev.hist[path] end,
        add_history = function(path, ts) dev.hist[path] = ts end,
        changed = function(path) dev.changed[path] = (dev.changed[path] or 0) + 1 end,
    }
    -- an existing metadata file, as KOReader leaves it after reading
    function dev.has(path, data)
        dev.meta[path] = data
        dev.clock = dev.clock + 1
        dev.mtime[path] = dev.clock
    end
    dev.id = id
    return dev
end

local drive = new_drive()
local function deps(dev, extra)
    local d = {
        network = drive.net, token = "tok", folders = { annotations = "ANN", progress = "PROG" },
        device = dev.id, device_id = dev.id, only_ahead = true, settings_key = "gdriveplus",
        md5 = drive.checksum,
        parse_time = function() return 1700000000 end,
        docs = dev.docs,
    }
    for k, v in pairs(extra or {}) do d[k] = v end
    return d
end

local function remote()
    return {
        ann = library.by_book(drive.net.listFolder(nil, "ANN")),
        prog = library.by_book(drive.net.listFolder(nil, "PROG")),
    }
end

--- One library sync: list Drive, plan, process every book.
local function run(dev, books, index, extra, skip)
    local queue = library.plan(remote(), books, index, dev.docs.sidecar_mtime, skip)
    local results = {}
    for _, item in ipairs(queue) do
        local res = library.process(item, deps(dev, extra))
        if res.index then index.books[item.path] = res.index end
        results[item.path] = res
    end
    return results, queue
end

local function epub(xp0, xp1, text, extra)
    local a = { page = xp0, pos0 = xp0, pos1 = xp1, text = text, drawer = "lighten",
        datetime = "2026-11-01 10:00:00", chapter = "One" }
    for k, v in pairs(extra or {}) do a[k] = v end
    return a
end
local function pdf(page, x, y, text)
    return {
        page = page, pos0 = { x = x, y = y, page = page, zoom = 1, rotation = 0 },
        pos1 = { x = x + 100, y = y + 10, page = page, zoom = 1, rotation = 0 },
        pboxes = { { x = x, y = y, w = 100, h = 10 } }, text = text, drawer = "lighten",
        datetime = "2026-11-01 10:00:00",
    }
end
local function put_annotations(file_name, list, book)
    book = book or { file = file_name, title = "T " .. file_name }
    return drive.put(file_name .. ".json", gjson.encode(annotations.build_doc(book, annotations.to_map(list))))
end
local function put_progress(file_name, rec)
    rec.version, rec.book = 2, { file = file_name }
    return drive.put(file_name .. ".json", gjson.encode(rec), nil, "PROG")
end
local function remote_progress(file_name)
    local f = drive.by_name(file_name .. ".json", "PROG")
    return f and gjson.decode(f.content)
end
local function remote_annotations(file_name)
    local f = drive.by_name(file_name .. ".json", "ANN")
    return f and gjson.decode(f.content).annotations
end

local XP1 = "/body/DocFragment[2]/body/p[3]/text().0"
local XP2 = "/body/DocFragment[2]/body/p[3]/text().12"
local XP_POS = "/body/DocFragment[5]/body/p[1]/text().0"

-- 0. Scanning the home folder ------------------------------------------------------
local tree = {
    ["/home"] = { "Kniha.epub", ".hidden", "Sub", "Kniha.sdr", "notes.txt", "Scan.pdf" },
    ["/home/.hidden"] = { "Secret.epub" },
    ["/home/Sub"] = { "Other.epub" },
    ["/home/Kniha.sdr"] = { "metadata.epub.lua" },
}
local scanned = library.scan("/home/", {
    dir = function(path)
        local list = tree[path]
        if not list then error("cannot open " .. path) end
        local i = 0
        return function() i = i + 1; return list[i] end
    end,
    mode = function(path) return tree[path] and "directory" or "file" end,
    is_book = function(path) return path:match("%.epub$") or path:match("%.pdf$") end,
})
local names = {}
for _, b in ipairs(scanned) do names[#names + 1] = b.path end
eq(table.concat(names, ","), "/home/Kniha.epub,/home/Scan.pdf,/home/Sub/Other.epub",
    "books found, hidden and metadata folders skipped")

-- 1. A book read only elsewhere, never opened here ------------------------------
local kindle = new_device("kindle")
local index = { version = 1, books = {} }
local books = {
    { path = "/b/Web.epub", name = "Web.epub" },
    { path = "/b/Gone.epub", name = "Gone.epub" },
    { path = "/b/Local.pdf", name = "Local.pdf" },
    { path = "/b/Open.epub", name = "Open.epub" },
}
put_annotations("Web.epub", { epub(XP1, XP2, "from the web") }, { file = "Web.epub", title = "Web Title" })
put_progress("Web.epub", { progress = XP_POS, percentage = 0.4, timestamp = 1800000000, device = "web", device_id = "web" })
local gone = annotations.to_map({ epub(XP1, XP2, "deleted") })
for _, v in pairs(gone) do v.deleted = true; v.datetime_updated = "2026-11-02 10:00:00" end
drive.put("Gone.epub.json", gjson.encode(annotations.build_doc({ file = "Gone.epub" }, gone)))
put_annotations("Open.epub", { epub(XP1, XP2, "open") })

local results, queue = run(kindle, books, index, nil, "/b/Open.epub")
local web = kindle.meta["/b/Web.epub"]
check(web ~= nil, "metadata is created for a book read elsewhere")
eq(results["/b/Web.epub"].status, "changed", "the book is reported as changed")
eq(#web.annotations, 1, "its annotation is there")
eq(web.annotations[1].text, "from the web", "…the right one")
eq(web.annotations_externally_modified, true, "KOReader sorts and renumbers it on opening")
eq(web.last_xpointer, XP_POS, "the position is there: the book opens where it was left")
eq(web.percent_finished, 0.4, "the file browser shows the progress")
eq(web.cre_dom_version, 20240114, "the DOM version is set, or KOReader would assume a very old book")
eq(web.partial_md5_checksum, "md5:/b/Web.epub", "the book's hash is stored")
eq(web.gdriveplus.progress_ts, 1800000000, "the position counts as taken over")
check(web.gdriveplus.unverified ~= nil, "EPUB annotations are checked on opening")
eq(kindle.hist["/b/Web.epub"], 1800000000, "the book is in the history at the time it was read")
check(files["/b/Web.sdr/gdriveplus.json"] ~= nil, "the sync snapshot is written")
eq(gjson.decode(remote_annotations and drive.by_name("Web.epub.json", "ANN").content).book.title, "Web Title",
    "the title on Drive is kept")
check(kindle.meta["/b/Gone.epub"] == nil, "only deleted annotations on Drive: no metadata created")
check(kindle.hist["/b/Gone.epub"] == nil, "…and not put into the history")
check(results["/b/Open.epub"] == nil, "the open book is left to its own sync")
check(results["/b/Local.pdf"] == nil, "a book with nothing anywhere is not looked at")

-- 2. Nothing changed: the next library sync costs the two listings ---------------
local before = drive.requests
results, queue = run(kindle, books, index, nil, "/b/Open.epub")
eq(#queue, 0, "nothing to do the second time")
eq(drive.requests - before, 2, "only the two folder listings are requested")

-- 3. A newer position from another device; one behind is not taken --------------
kindle.has("/b/Read.epub", { last_xpointer = XP1, percent_finished = 0.2, cre_dom_version = 20240114,
    gdriveplus = { progress_ts = 1700000000 } })
put_progress("Read.epub", { progress = XP_POS, percentage = 0.5, timestamp = 1800000000, device = "win", device_id = "win" })
kindle.has("/b/Behind.epub", { last_xpointer = XP_POS, percent_finished = 0.7, cre_dom_version = 20240114,
    gdriveplus = { progress_ts = 1700000000 } })
put_progress("Behind.epub", { progress = XP1, percentage = 0.1, timestamp = 1800000000, device = "win", device_id = "win" })
books = { { path = "/b/Read.epub", name = "Read.epub" }, { path = "/b/Behind.epub", name = "Behind.epub" } }
results = run(kindle, books, index)
eq(kindle.meta["/b/Read.epub"].last_xpointer, XP_POS, "a newer position from elsewhere is taken over")
eq(kindle.meta["/b/Read.epub"].percent_finished, 0.5, "…with its percentage")
eq(kindle.meta["/b/Behind.epub"].last_xpointer, XP_POS, "a position before this one is not (only further on)")
eq(results["/b/Behind.epub"].status, "unchanged", "…and nothing is reported")
eq(remote_progress("Behind.epub").percentage, 0.1, "…nor pushed over the newer one")
eq(#(select(2, run(kindle, books, index))), 0, "no change after the run")
local phone = new_device("phone")
phone.has("/w/Behind.epub", { last_xpointer = XP_POS, percent_finished = 0.7, cre_dom_version = 20240114,
    gdriveplus = { progress_ts = 1700000000 } })
run(phone, { { path = "/w/Behind.epub", name = "Behind.epub" } }, { version = 1, books = {} }, { only_ahead = false })
eq(phone.meta["/w/Behind.epub"].last_xpointer, XP1, "with that setting off, the newer position is taken even if behind")

-- 4. A position with only a percentage (or an xpointer not usable here) ----------
kindle.has("/b/Pct.epub", { last_xpointer = XP1, percent_finished = 0.2, cre_dom_version = 20240114 })
kindle.hist["/b/Pct.epub"] = 1700000000
put_progress("Pct.epub", { percentage = 0.6, timestamp = 1800000000, device = "web", device_id = "web" })
kindle.has("/b/OldDom.epub", { last_xpointer = XP1, percent_finished = 0.2, cre_dom_version = 20171225,
    gdriveplus = { progress_ts = 1700000000 } })
put_progress("OldDom.epub", { progress = XP_POS, percentage = 0.6, timestamp = 1800000000, device = "win", device_id = "win" })
books = { { path = "/b/Pct.epub", name = "Pct.epub" }, { path = "/b/OldDom.epub", name = "OldDom.epub" } }
run(kindle, books, index)
local pct = kindle.meta["/b/Pct.epub"]
eq(pct.last_xpointer, XP1, "without an xpointer the position here stays…")
eq(pct.percent_finished, 0.6, "…but the progress shown is the newer one")
eq(pct.gdriveplus.progress_ts, 1700000000, "the jump is still offered when the book is opened")
eq(kindle.meta["/b/OldDom.epub"].last_xpointer, XP1, "an xpointer is not written into a book on an old DOM version")
eq(kindle.meta["/b/OldDom.epub"].percent_finished, 0.6, "…only its percentage")
-- KOReader rewrites the file (its time changes): still nothing is pushed back
kindle.mtime["/b/Pct.epub"] = kindle.mtime["/b/Pct.epub"] + 50
local sent = remote_progress("Pct.epub")
results = run(kindle, books, index)
eq(results["/b/Pct.epub"].status, "unchanged", "the old position here is not taken for a newer one")
eq(remote_progress("Pct.epub").timestamp, sent.timestamp, "nothing pushed")

-- 5. Read here more recently: pushed with the time it was read -----------------
kindle.has("/b/Mine.pdf", { last_page = 42, percent_finished = 0.3, doc_pages = 140,
    gdriveplus = { progress_ts = 1900000000 } })
put_progress("Mine.pdf", { progress = 10, percentage = 0.07, timestamp = 1800000000, device = "win", device_id = "win" })
books = { { path = "/b/Mine.pdf", name = "Mine.pdf" } }
results = run(kindle, books, index)
local mine = remote_progress("Mine.pdf")
eq(mine.progress, 42, "the newer page here is pushed")
eq(mine.timestamp, 1900000000, "…stamped with the time it was read, not the upload")
eq(mine.device_id, "kindle", "…from this device")
eq(mine.pages, 140, "…with the page count")
eq(#(select(2, run(kindle, books, index))), 0, "and the pushed file is not looked at again")

-- 6. A PDF page from elsewhere ----------------------------------------------------
put_progress("Paper.pdf", { progress = 17, percentage = 0.5, timestamp = 1800000000, device = "win", device_id = "win" })
run(kindle, { { path = "/b/Paper.pdf", name = "Paper.pdf" } }, index)
eq(kindle.meta["/b/Paper.pdf"].last_page, 17, "a PDF gets its page")
check(kindle.meta["/b/Paper.pdf"].cre_dom_version == nil, "no DOM version for a PDF")

-- 7. Changed in a closed book (e.g. a note edited by an annotation viewer) ------
local note_book = { { path = "/b/Web.epub", name = "Web.epub" } }
local meta = kindle.meta["/b/Web.epub"]
meta.annotations[1].note = "edited elsewhere on this device"
meta.annotations[1].datetime_updated = "2026-11-19 09:00:00"
kindle.has("/b/Web.epub", meta)
results = run(kindle, note_book, index)
eq(results["/b/Web.epub"].status, "changed", "the edited book is synced")
local web_remote = remote_annotations("Web.epub")
local edited
for _, a in pairs(web_remote) do edited = a end
eq(edited.note, "edited elsewhere on this device", "the edited note reaches Drive")
eq(#(select(2, run(kindle, note_book, index))), 0, "and is not uploaded again")

-- 8. A book with annotations and a position that are not on Drive yet ----------
kindle.has("/b/Only.pdf", { annotations = { pdf(3, 10, 10, "mine") }, last_page = 3, percent_finished = 0.1,
    gdriveplus = { progress_ts = 1750000000 } })
results = run(kindle, { { path = "/b/Only.pdf", name = "Only.pdf" } }, index)
check(remote_annotations("Only.pdf") ~= nil, "its annotations are uploaded")
eq(remote_progress("Only.pdf").progress, 3, "its position is uploaded")

-- 9. Metadata in KOReader's old annotation format -----------------------------
kindle.has("/b/Old.epub", { highlight = { [3] = { { text = "old" } } }, last_xpointer = XP1, percent_finished = 0.1,
    cre_dom_version = 20240114, gdriveplus = { progress_ts = 1700000000 } })
put_annotations("Old.epub", { epub(XP1, XP2, "new") })
put_progress("Old.epub", { progress = XP_POS, percentage = 0.3, timestamp = 1800000000, device = "win", device_id = "win" })
results = run(kindle, { { path = "/b/Old.epub", name = "Old.epub" } }, index)
check(kindle.meta["/b/Old.epub"].annotations == nil, "old-format annotations are left for KOReader to convert")
eq(#results["/b/Old.epub"].notes, 1, "…which is reported")
eq(kindle.meta["/b/Old.epub"].last_xpointer, XP_POS, "the position is still synced")

-- 10. A failing download leaves the book for the next time ----------------------
put_progress("Fail.epub", { progress = XP_POS, percentage = 0.3, timestamp = 1800000000, device = "win", device_id = "win" })
local real_download = drive.net.download
drive.net.download = function() return nil, "HTTP 503: try later", 503 end
results = run(kindle, { { path = "/b/Fail.epub", name = "Fail.epub" } }, index)
drive.net.download = real_download
eq(results["/b/Fail.epub"].status, "failed", "a failure is reported")
check(index.books["/b/Fail.epub"] == nil, "…and the book is tried again next time")
results = run(kindle, { { path = "/b/Fail.epub", name = "Fail.epub" } }, index)
eq(results["/b/Fail.epub"].status, "changed", "the next run succeeds")

-- 11. Index bookkeeping ----------------------------------------------------------
library.prune(index, { { path = "/b/Web.epub" } })
check(index.books["/b/Web.epub"] ~= nil and index.books["/b/Mine.pdf"] == nil, "books no longer present are forgotten")
local dup = library.by_book({
    { name = "A.epub.json", id = "old", modifiedTime = "2026-01-01T00:00:00.000Z" },
    { name = "A.epub.json", id = "new", modifiedTime = "2026-02-01T00:00:00.000Z" },
    { name = "notes.txt", id = "x" },
})
eq(dup["A.epub"].id, "new", "of two files with one name the newer is used")
check(dup["notes.txt"] == nil, "other files are ignored")

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
