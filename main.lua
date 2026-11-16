--- Google Drive Plus for KOReader.
--- Fork of moohaad/gdrive.koplugin (MIT). See README.md and SYNC_FORMAT.md.

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local network = require("gdriveplus_network")
local progress = require("gdriveplus_progress")
local sync = require("gdriveplus_sync")
local utils = require("gdriveplus_utils")

local SETTINGS_KEY = "gdriveplus"
local LEGACY_SETTINGS_KEY = "gdrive" -- settings of the original gdrive.koplugin
local SYNC_FOLDER = "KOReader_Sync"
local VOCAB_NAME = "vocabulary_builder.sqlite3"
local STATS_NAME = "statistics.sqlite3"     -- KOReader's reading statistics
local STATS_INTERVAL = 12 * 3600            -- upload at most twice a day automatically
local CHANGE_SYNC_DELAY = 20                -- seconds of quiet after an annotation change before syncing it
local PULL_WAIT = 5 * 60                    -- after opening/waking, pull once Wi-Fi connects within this time
local LEAVE_PUSH_GAP = 30                   -- one sleep can send several "leaving" events; push once
local PUSH_QUIET = 10                       -- while reading, push the position this long after a page turn
local IDLE_PULL_AFTER = 2 * 60              -- a book left on one page this long looks for a newer position
local IDLE_PULL_LIMIT = 2 * 3600            -- ... but not for longer than this
local PROGRESS_INTERVALS = { 2, 5, 10, 15, 30, 60 } -- minutes, offered in Settings

local GDrivePlus = WidgetContainer:extend{
    name = "gdriveplus",
    is_doc_only = false,
    settings = nil,
    history = nil,
}

GDrivePlus.default_settings = {
    client_id = "",
    client_secret = "",
    refresh_token = "",
    access_token = "",
    token_expiry = 0,
    download_dir = "",
    auto_sync = true,       -- sync annotations when a book is opened/closed and on sleep/wake
    sync_on_change = true,  -- also sync annotations shortly after each change (only when online)
    sync_progress = true,   -- pull progress on open/wake, push on close/sleep
    progress_interval = 2,  -- minutes between position pushes while reading (0 = only open/close/sleep/wake)
    confirm_jump = true,    -- ask before jumping to a newer position from another device
    device_name = "",       -- shown to other devices and in the web reader; empty = the model name
    sync_vocabulary = true, -- include the vocabulary builder database
    upload_statistics = true, -- upload reading statistics (for the web reader), at most twice a day
    last_error = "",
}

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

function GDrivePlus:init()
    self.history = {}
    local settings = G_reader_settings:readSetting(SETTINGS_KEY)
    if type(settings) ~= "table" then
        -- First run: take over credentials from the original plugin, if any.
        settings = {}
        local legacy = G_reader_settings:readSetting(LEGACY_SETTINGS_KEY)
        if type(legacy) == "table" then
            for _, k in ipairs({ "client_id", "client_secret", "refresh_token", "download_dir",
                "auto_sync", "sync_progress", "sync_vocabulary" }) do
                settings[k] = legacy[k]
            end
        end
    end
    for k, v in pairs(self.default_settings) do
        if settings[k] == nil then settings[k] = v end
    end
    if settings.download_dir == "" or settings.download_dir == "/mnt/onboard/downloads"
        and not lfs.attributes("/mnt/onboard/downloads") then
        settings.download_dir = G_reader_settings:readSetting("home_dir") or DataStorage:getDataDir()
    end
    if type(settings.device_id) ~= "string" then
        math.randomseed(os.time())
        settings.device_id = string.format("%08x%06x", os.time(), math.random(0, 0xffffff))
    end
    self.settings = settings
    self.pull_task = function() self:runPendingPull() end
    self.change_task = function() self:syncChangedAnnotations() end
    self.push_task = function() self:runPeriodicPush() end
    self.idle_task = function() self:runIdlePull() end
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function GDrivePlus:save()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
    if G_reader_settings.flush then G_reader_settings:flush() end
end

--- The name other devices and the web reader see: the user's own name for this
--- device, or else its model.
function GDrivePlus:deviceName()
    local name = self.settings.device_name
    if type(name) == "string" and name ~= "" then return name end
    local Device = require("device")
    return tostring(Device.model or "KOReader")
end

function GDrivePlus:editDeviceName(on_saved)
    local InputDialog = require("ui/widget/inputdialog")
    local Device = require("device")
    local dialog
    dialog = InputDialog:new{
        title = _("Device name"),
        input = self.settings.device_name or "",
        input_hint = tostring(Device.model or "KOReader"),
        description = _("Shown on your other devices when they offer to jump to the position you left, and in the web reader's statistics. Leave empty to use the model name."),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local name = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                    self.settings.device_name = name
                    self:save()
                    UIManager:close(dialog)
                    if on_saved then on_saved() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function GDrivePlus:isConfigured()
    return self.settings.client_id ~= "" and self.settings.refresh_token ~= ""
end

function GDrivePlus:onDispatcherRegisterActions()
    Dispatcher:registerAction("gdriveplus_sync", {
        category = "none", event = "GDrivePlusNow",
        title = _("Google Drive: sync this book"), reader = true,
    })
end

function GDrivePlus:onGDrivePlusNow()
    self:syncNow()
    return true
end

function GDrivePlus:toggle(key)
    self.settings[key] = not self.settings[key]
    self:save()
end

function GDrivePlus:progressIntervalMenu()
    local function item(minutes, text)
        return {
            text = text,
            radio = true,
            checked_func = function() return (tonumber(self.settings.progress_interval) or 0) == minutes end,
            callback = function() self:setProgressInterval(minutes) end,
        }
    end
    local items = { item(0, _("Off (only on open/close and sleep/wake)")) }
    for i = 1, #PROGRESS_INTERVALS do
        local m = PROGRESS_INTERVALS[i]
        table.insert(items, item(m, m == 60 and _("Every hour") or T(_("Every %1 minutes"), m)))
    end
    return items
end

function GDrivePlus:addToMainMenu(menu_items)
    menu_items.gdriveplus = {
        text = _("Google Drive Plus"),
        sorting_hint = "tools",
        sub_item_table = {
            { text = _("Sync this book now"), callback = function() self:syncNow() end },
            { text = _("Push reading progress"), callback = function() self:pushProgress(true) end },
            { text = _("Pull reading progress"), callback = function() self:pullProgress(true) end },
            { text = _("Sync vocabulary"), callback = function() self:syncVocabulary(true) end },
            { text = _("Upload reading statistics"), callback = function() self:uploadStatistics() end,
              separator = true },
            { text = _("Browse Google Drive"), callback = function() self.history = {}; self:browse() end,
              separator = true },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text = _("Sync annotations on open/close and sleep/wake"),
                        checked_func = function() return self.settings.auto_sync end,
                        callback = function() self:toggle("auto_sync") end,
                    },
                    {
                        text = _("Sync annotations shortly after each change"),
                        enabled_func = function() return self.settings.auto_sync end,
                        checked_func = function() return self.settings.auto_sync and self.settings.sync_on_change end,
                        callback = function() self:toggle("sync_on_change") end,
                    },
                    {
                        text = _("Sync reading progress on open/close and sleep/wake"),
                        checked_func = function() return self.settings.sync_progress end,
                        callback = function() self:toggle("sync_progress") end,
                    },
                    {
                        text_func = function()
                            local m = tonumber(self.settings.progress_interval) or 0
                            if m == 0 then return _("Sync reading progress while reading: off") end
                            return T(_("Sync reading progress while reading: every %1 min"), m)
                        end,
                        enabled_func = function() return self.settings.sync_progress end,
                        sub_item_table = self:progressIntervalMenu(),
                    },
                    {
                        text = _("Ask before jumping to a position from another device"),
                        enabled_func = function() return self.settings.sync_progress end,
                        checked_func = function() return self.settings.confirm_jump end,
                        callback = function() self:toggle("confirm_jump") end,
                    },
                    {
                        text = _("Sync vocabulary on open/close and sleep/wake"),
                        checked_func = function() return self.settings.sync_vocabulary end,
                        callback = function() self:toggle("sync_vocabulary") end,
                    },
                    {
                        text = _("Upload reading statistics twice a day"),
                        checked_func = function() return self.settings.upload_statistics end,
                        callback = function() self:toggle("upload_statistics") end,
                        separator = true,
                    },
                    {
                        text_func = function() return T(_("Device name: %1"), self:deviceName()) end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:editDeviceName(function()
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end)
                        end,
                        separator = true,
                    },
                    { text = _("Load client ID (client_id.json)"), callback = function()
                        self:guarded("load client ID", function() self:loadClientIDFromJson() end)
                    end },
                    { text = _("Load refresh token (refresh_token.txt)"), callback = function()
                        self:guarded("load refresh token", function() self:loadRefreshTokenFromFile() end)
                    end },
                    { text = _("Set download folder"), callback = function() self:setDownloadDir() end },
                    { text = _("Show last error"), callback = function() self:showLastError() end },
                    { text = _("Forget cached Drive folders"), callback = function()
                        self.settings.folders = nil
                        self:save()
                        self:info(_("Folder cache cleared."), 2)
                    end },
                    { text = _("Clear credentials"), callback = function() self:clearAuth() end },
                },
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- UI helpers
-- ---------------------------------------------------------------------------

function GDrivePlus:info(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

function GDrivePlus:recordError(what, err)
    err = tostring(err or "unknown error")
    logger.warn("GDrivePlus:", what, "-", err)
    self.settings.last_error = os.date("%Y-%m-%d %H:%M:%S") .. "  " .. what .. "\n" .. err
    if err:find("HTTP 404", 1, true) then
        -- A cached folder id no longer exists on Drive; look it up again next time.
        self.settings.folders = nil
    end
    self:save()
end

function GDrivePlus:showLastError()
    local text = self.settings.last_error
    if not text or text == "" then text = _("No errors recorded.") end
    self:info(text)
end

local function isConnected()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok then return true end
    local ok2, res = pcall(NetworkMgr.isConnected, NetworkMgr)
    if not ok2 then return true end
    return res
end

--- Call `fn`, catching any Lua error so it cannot take KOReader down.
--- @return ok, then fn's results (text, timeout) or the error with a traceback
local function runCaught(fn)
    return xpcall(fn, function(e)
        return tostring(e) .. "\n" .. debug.traceback()
    end)
end

--- Show what a `runCaught` call produced: the error (recorded under `what`, see
--- Settings → Show last error), or `text` when there is one.
function GDrivePlus:showOutcome(what, ok, text, timeout)
    if not ok then
        self:recordError(what, text)
        self:info(_("Unexpected error:") .. "\n" .. tostring(text):match("^[^\n]*"))
    elseif text then
        self:info(text, timeout)
    end
end

--- Run a menu action that needs no network; an error is shown instead of crashing.
--- `fn` may return the text to show afterwards and a timeout.
function GDrivePlus:guarded(what, fn)
    self:showOutcome(what, runCaught(fn))
end

--- Run `fn` with a "working…" message, after making sure we are online.
--- `fn` returns the text to show afterwards (or nil for nothing) and a timeout.
function GDrivePlus:interactive(title, fn)
    local function work()
        local msg = InfoMessage:new{ text = title }
        UIManager:show(msg)
        UIManager:forceRePaint()
        local ok, text, timeout = runCaught(fn)
        UIManager:close(msg)
        self:showOutcome(title, ok, text, timeout)
    end
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and type(NetworkMgr.runWhenOnline) == "function" then
        NetworkMgr:runWhenOnline(work)
    else
        work()
    end
end

-- ---------------------------------------------------------------------------
-- Credentials
-- ---------------------------------------------------------------------------

function GDrivePlus:getPluginDir()
    local source = debug.getinfo(1).source
    if source:sub(1, 1) == "@" then
        local dir = source:sub(2):match("(.*[/\\])") or "./"
        if dir:sub(1, 1) ~= "/" then
            local cwd = lfs.currentdir()
            if cwd then dir = cwd .. "/" .. dir end
        end
        return dir
    end
    return "./"
end

--- Places where client_id.json / refresh_token.txt are looked for: a `gdriveplus`
--- folder in KOReader's folder, then the plugin's own folder. The original plugin's
--- `gdrive` folder is deliberately not searched.
function GDrivePlus:credentialPaths(filename)
    local paths, seen = {}, {}
    local function add(path)
        if not seen[path] then
            seen[path] = true
            table.insert(paths, path)
        end
    end
    local base = DataStorage:getFullDataDir() or DataStorage:getDataDir()
    local plugin_dir = self:getPluginDir()
    local ko_dir = plugin_dir:match("^(.*[/\\])plugins[/\\]")
    add(base .. "/gdriveplus/" .. filename)
    if ko_dir then add(ko_dir .. "gdriveplus/" .. filename) end
    add(plugin_dir .. filename)
    return paths
end

function GDrivePlus:findCredentialFile(filename)
    local paths = self:credentialPaths(filename)
    for _, path in ipairs(paths) do
        if lfs.attributes(path, "mode") == "file" then return path end
    end
    return nil, paths
end

function GDrivePlus:loadClientIDFromJson()
    local found, searched = self:findCredentialFile("client_id.json")
    if not found then
        self:info(_("client_id.json not found in:") .. "\n" .. table.concat(searched, "\n"))
        return
    end
    local data = utils.read_json(found)
    local info = data and (data.installed or data.web)
    if type(info) == "table" and type(info.client_id) == "string" then
        self.settings.client_id = info.client_id
        self.settings.client_secret = info.client_secret or ""
        self.settings.access_token = ""
        self.settings.token_expiry = 0
        self:save()
        self:info(_("Client ID loaded."), 3)
    else
        self:info(_("Invalid client_id.json at:") .. "\n" .. found)
    end
end

function GDrivePlus:loadRefreshTokenFromFile()
    local found, searched = self:findCredentialFile("refresh_token.txt")
    if not found then
        self:info(_("refresh_token.txt not found in:") .. "\n" .. table.concat(searched, "\n"))
        return
    end
    local content = utils.read_file(found)
    if not content then
        self:info(_("Cannot read:") .. "\n" .. found)
        return
    end
    local token = content:gsub("%s+", "")
    if token == "" then
        self:info(_("refresh_token.txt is empty:") .. "\n" .. found)
        return
    end
    self.settings.refresh_token = token
    self.settings.access_token = ""
    self.settings.token_expiry = 0
    self:save()
    self:info(_("Refresh token loaded."), 3)
end

function GDrivePlus:clearAuth()
    UIManager:show(ConfirmBox:new{
        text = _("Clear all Google Drive credentials?"),
        ok_callback = function()
            for _, k in ipairs({ "client_id", "client_secret", "refresh_token", "access_token" }) do
                self.settings[k] = ""
            end
            self.settings.token_expiry = 0
            self.settings.folders = nil
            self:save()
            self:info(_("Credentials cleared."), 2)
        end,
    })
end

--- @return access token — or nil, error
function GDrivePlus:getToken()
    if not self:isConfigured() then
        return nil, _("Setup required: load client_id.json and refresh_token.txt in Settings.")
    end
    if self.settings.access_token ~= "" and os.time() < (self.settings.token_expiry or 0) - 60 then
        return self.settings.access_token
    end
    local data, err = network.refreshToken(self.settings.client_id, self.settings.client_secret,
        self.settings.refresh_token)
    if not data then
        local hint = ""
        if tostring(err):find("invalid_grant", 1, true) or tostring(err):find("expired", 1, true) then
            hint = "\n" .. _("The refresh token is no longer valid. Tokens of Google apps in \"Testing\" status expire after 7 days: publish the app (Audience → Publish app), then create a new token and load it again. See the plugin's README.")
        end
        return nil, _("Cannot get access token:") .. " " .. tostring(err) .. hint
    end
    self.settings.access_token = data.access_token
    self.settings.token_expiry = os.time() + (tonumber(data.expires_in) or 3600)
    self:save()
    return data.access_token
end

--- Resolve (and cache) the ids of KOReader_Sync and its subfolders.
--- @param which "root" | "annotations" | "progress"
function GDrivePlus:getFolder(token, which)
    local folders = self.settings.folders
    if type(folders) ~= "table" then
        folders = {}
        self.settings.folders = folders
    end
    if not folders.root then
        local id, err = network.ensureFolder(token, SYNC_FOLDER, nil)
        if not id then return nil, _("Cannot access the sync folder:") .. " " .. tostring(err) end
        folders.root = id
        self:save()
    end
    if which == "root" then return folders.root end
    if not folders[which] then
        local id, err = network.ensureFolder(token, which, folders.root)
        if not id then return nil, _("Cannot access the sync folder:") .. " " .. tostring(err) end
        folders[which] = id
        self:save()
    end
    return folders[which]
end

-- ---------------------------------------------------------------------------
-- Per-book context
-- ---------------------------------------------------------------------------

function GDrivePlus:bookContext()
    local ui = self.ui
    local doc = ui and ui.document
    local file = doc and doc.file
    if not file or not ui.doc_settings then
        return nil, _("Please open a book first.")
    end
    local hash = ui.doc_settings:readSetting("partial_md5_checksum")
    if type(hash) ~= "string" or hash == "" then hash = util.partialMD5(file) end
    if not hash then return nil, _("Cannot hash the book file.") end

    local sdr_dir = DocSettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then return nil, _("Cannot determine the book's metadata folder.") end
    if not lfs.attributes(sdr_dir) then util.makePath(sdr_dir) end

    local cache = ui.doc_settings:readSetting(SETTINGS_KEY)
    if type(cache) ~= "table" then cache = {} end

    local name = utils.basename(file)
    local props = ui.doc_props or {}
    local paging = ui.paging ~= nil
    return {
        ui = ui,
        paging = paging,
        sdr_dir = sdr_dir,
        remote_name = name .. ".json",
        cache = cache,
        device = self:deviceName(),
        device_id = self.settings.device_id,
        book = {
            file = name,
            title = props.display_title or props.title,
            authors = props.authors,
            partial_md5 = hash,
            paging = paging,
        },
    }
end

function GDrivePlus:saveBookCache(ctx)
    local ds = ctx.ui.doc_settings
    if not ds then return end
    ds:saveSetting(SETTINGS_KEY, ctx.cache)
    if type(ds.flush) == "function" then pcall(ds.flush, ds) end
end

-- ---------------------------------------------------------------------------
-- Sync operations (all synchronous; each returns ok, message)
-- ---------------------------------------------------------------------------

function GDrivePlus:doSyncAnnotations(token, ctx, only_if_changed)
    local folder_id, err = self:getFolder(token, "annotations")
    if not folder_id then return false, err end
    ctx.folder_id = folder_id
    ctx.only_if_changed = only_if_changed
    local ok, res = sync.run(network, token, ctx)
    self:saveBookCache(ctx)
    if not ok then return false, res end
    return true, res
end

function GDrivePlus:doPushProgress(token, ctx)
    local folder_id, err = self:getFolder(token, "progress")
    if not folder_id then return false, err end
    ctx.folder_id = folder_id
    local ok, perr = progress.push(network, token, ctx)
    self:saveBookCache(ctx)
    if ok then
        self.progress_dirty = false
        self.last_push = os.time()
    end
    return ok, perr
end

function GDrivePlus:doPullProgress(token, ctx, force)
    local folder_id, err = self:getFolder(token, "progress")
    if not folder_id then return nil, err end
    ctx.folder_id = folder_id
    ctx.confirm = self.settings.confirm_jump
    -- Jumping to the pulled position turns the page; that is not the reader's doing
    -- and must not be pushed back (see positionChanged).
    self.applying_remote = true
    local ok, status, detail = pcall(progress.pull, network, token, ctx, force)
    self.applying_remote = false
    if not ok then error(status, 0) end
    if status == "moved" then self.remote_applied_at = os.time() end
    self:saveBookCache(ctx)
    if status == "newer" then
        self:askJump(ctx, detail)
        return "asked"
    end
    return status, detail
end

--- "page 45 of 320 (14 %)", "~page 45 of 320 (14 %)" or "14 %"
local function formatPosition(info)
    local text
    if info.page then
        local page = (info.approx and "~" or "") .. tostring(info.page)
        text = info.pages and T(_("page %1 of %2"), page, info.pages) or T(_("page %1"), page)
        if info.percent then text = text .. " (" .. info.percent .. " %)" end
    elseif info.percent then
        text = info.percent .. " %"
    end
    return text or _("unknown")
end

--- "2026-11-16 14:32 (5 min ago)"
local function formatWhen(ts)
    local text = os.date("%Y-%m-%d %H:%M", ts)
    local ago = os.time() - ts
    if ago >= 0 and ago < 3600 then
        text = text .. " (" .. T(_("%1 min ago"), math.max(1, math.floor(ago / 60))) .. ")"
    elseif ago >= 3600 and ago < 48 * 3600 then
        text = text .. " (" .. T(_("%1 h ago"), math.floor(ago / 3600)) .. ")"
    end
    return text
end

--- Show where another device left the book and jump there only if the user agrees.
--- Declining keeps this position and is not asked again for the same remote one.
function GDrivePlus:askJump(ctx, remote)
    if self.jump_dialog then return end -- already asking
    local ui = ctx.ui
    local here = progress.describe(ui, progress.get_current(ui))
    local there = progress.describe(ui, remote)
    local device = type(remote.device) == "string" and remote.device ~= "" and remote.device
        or _("another device")
    local lines = {
        _("Newer reading position from another device"),
        "",
        T(_("Device: %1"), device),
    }
    local ts = tonumber(remote.timestamp)
    if ts and ts > 0 then table.insert(lines, T(_("Saved: %1"), formatWhen(ts))) end
    table.insert(lines, "")
    table.insert(lines, _("Here:") .. " " .. formatPosition(here))
    if here.chapter then table.insert(lines, "    " .. here.chapter) end
    table.insert(lines, _("There:") .. " " .. formatPosition(there))
    if there.chapter then table.insert(lines, "    " .. there.chapter) end
    table.insert(lines, "")
    table.insert(lines, _("Go to the position from the other device?"))

    self.jump_dialog = ConfirmBox:new{
        text = table.concat(lines, "\n"),
        ok_text = _("Go there"),
        cancel_text = _("Stay here"),
        dismissable = false,
        ok_callback = function()
            self.jump_dialog = nil
            if not (self.ui and self.ui.document) then return end
            self.applying_remote = true
            local ok, moved = pcall(progress.apply, ctx, remote)
            self.applying_remote = false
            self.remote_applied_at = os.time()
            self:saveBookCache(ctx)
            if not (ok and moved) then
                self:recordError("pull progress", ok and "remote position cannot be used" or moved)
                self:info(_("This position cannot be used in this book."), 3)
            end
        end,
        cancel_callback = function()
            self.jump_dialog = nil
            if not (self.ui and self.ui.document) then return end
            -- treat this remote position as seen; only a newer one asks again
            ctx.cache.progress_ts = math.max(tonumber(ctx.cache.progress_ts) or 0, ts or 0)
            self:saveBookCache(ctx)
        end,
    }
    UIManager:show(self.jump_dialog)
end

--- Parse a Drive RFC 3339 timestamp ("2024-01-15T10:30:00.000Z", UTC) to epoch.
function GDrivePlus:parseGDriveTime(time_str)
    if not time_str or time_str == "" then return 0 end
    local year, month, day, hour, min, sec = time_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not year then return 0 end
    -- os.time() interprets the table as local time; shift back to UTC.
    local t = os.time({
        year = tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec), isdst = false,
    })
    local utc = os.date("!*t", t)
    utc.isdst = false
    local tz_offset = t - os.time(utc)
    return t + tz_offset
end

--- Two-way sync of the vocabulary builder database (newest file wins).
--- @return ok, message
function GDrivePlus:doSyncVocabulary(token)
    local local_path = DataStorage:getSettingsDir() .. "/" .. VOCAB_NAME
    local local_mtime = lfs.attributes(local_path, "modification")
    local folder_id, err = self:getFolder(token, "root")
    if not folder_id then return false, err end

    local remote, ferr = network.findFile(token, VOCAB_NAME, { parent_id = folder_id })
    if ferr then return false, ferr end

    local function upload(id)
        local content = utils.read_file(local_path)
        if not content then return false, "cannot read local vocabulary" end
        local new_id, uerr = network.upload(token, {
            id = id, name = VOCAB_NAME, parent_id = folder_id,
            content = content, mime = "application/x-sqlite3",
        })
        if not new_id then return false, uerr end
        return true, _("Vocabulary uploaded.")
    end
    local function download()
        local ok, derr = network.downloadToFile(token, remote.id, local_path)
        if not ok then return false, derr end
        return true, _("Vocabulary downloaded.")
    end

    if remote and local_mtime then
        local remote_mtime = self:parseGDriveTime(remote.modifiedTime)
        local THRESHOLD = 10
        if local_mtime > remote_mtime + THRESHOLD then
            return upload(remote.id)
        elseif remote_mtime > local_mtime + THRESHOLD then
            return download()
        end
        return true, _("Vocabulary already in sync.")
    elseif remote then
        return download()
    elseif local_mtime then
        return upload(nil)
    end
    return true, _("No vocabulary data found.")
end

--- File name of this device's statistics on Drive: "<device name> <id>.sqlite3".
--- A renamed device renames its file on the next upload (same file id).
function GDrivePlus:statisticsFileName()
    local name = (self:deviceName():gsub('[\\/:*?"<>|]', "_"))
    return name .. " " .. tostring(self.settings.device_id):sub(-6) .. ".sqlite3"
end

--- Upload KOReader's reading statistics database to KOReader_Sync/statistics/,
--- one file per device, for the web reader to show. Never downloads: each
--- device's statistics stay its own.
--- @return ok, message
function GDrivePlus:doUploadStatistics(token)
    local path = DataStorage:getSettingsDir() .. "/" .. STATS_NAME
    if lfs.attributes(path, "mode") ~= "file" then
        return true, _("No reading statistics on this device.")
    end
    -- Fold the write-ahead log into the database file, so the upload has the
    -- latest data. PASSIVE never waits for or disturbs other connections.
    local cok, cerr = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(path)
        conn:exec("PRAGMA wal_checkpoint(PASSIVE);")
        conn:close()
    end)
    if not cok then logger.warn("GDrivePlus: statistics checkpoint failed", cerr) end

    local content = utils.read_file(path)
    if not content then return false, "cannot read " .. STATS_NAME end
    local folder_id, err = self:getFolder(token, "statistics")
    if not folder_id then return false, err end
    local name = self:statisticsFileName()
    local id = self.settings.statistics_file_id
    if not id then
        local existing, ferr = network.findFile(token, name, { parent_id = folder_id })
        if ferr then return false, ferr end
        id = existing and existing.id
    end
    local args = { id = id, name = name, parent_id = folder_id, content = content, mime = "application/x-sqlite3" }
    local new_id, uerr = network.upload(token, args)
    if not new_id and id and tostring(uerr):find("404", 1, true) then
        -- the file was deleted on Drive: create it again
        args.id = nil
        new_id, uerr = network.upload(token, args)
    end
    if not new_id then return false, uerr end
    self.settings.statistics_file_id = new_id
    self.settings.statistics_uploaded_at = os.time()
    self:save()
    return true, _("Reading statistics uploaded.")
end

-- ---------------------------------------------------------------------------
-- Menu actions
-- ---------------------------------------------------------------------------

function GDrivePlus:uploadStatistics()
    self:interactive(_("Uploading reading statistics…"), function()
        local token, err = self:getToken()
        if not token then return err end
        local ok, msg = self:doUploadStatistics(token)
        if not ok then
            self:recordError("statistics", msg)
            return _("Upload failed:") .. "\n" .. tostring(msg)
        end
        return msg, 3
    end)
end

local function describe(stats)
    if stats.skipped_unchanged then return _("Nothing to sync.") end
    local text = T(_("Synced. %1 annotations."), stats.total)
    if stats.pulled then text = text .. "\n" .. _("Annotations from other devices were added.") end
    if stats.invalid and stats.invalid > 0 then
        text = text .. "\n" .. T(_("%1 remote annotations could not be used in this book."), stats.invalid)
    end
    return text
end

function GDrivePlus:syncNow()
    local ctx, cerr = self:bookContext()
    if not ctx then return self:info(cerr, 3) end
    self:interactive(_("Syncing with Google Drive…"), function()
        local token, err = self:getToken()
        if not token then
            self:recordError("token", err)
            return err
        end
        local ok, res = self:doSyncAnnotations(token, ctx, false)
        if not ok then
            self:recordError("annotation sync", res)
            return _("Sync failed:") .. "\n" .. tostring(res)
        end
        local text = describe(res)
        if self.settings.sync_progress then
            local pok, perr = self:doPushProgress(token, ctx)
            if not pok then
                self:recordError("push progress", perr)
                text = text .. "\n" .. _("Progress not pushed:") .. " " .. tostring(perr)
            end
        end
        return text, 4
    end)
end

function GDrivePlus:pushProgress()
    local ctx, cerr = self:bookContext()
    if not ctx then return self:info(cerr, 3) end
    self:interactive(_("Pushing reading progress…"), function()
        local token, err = self:getToken()
        if not token then return err end
        local ok, perr = self:doPushProgress(token, ctx)
        if not ok then
            self:recordError("push progress", perr)
            return _("Push failed:") .. "\n" .. tostring(perr)
        end
        return _("Progress pushed."), 3
    end)
end

function GDrivePlus:pullProgress()
    local ctx, cerr = self:bookContext()
    if not ctx then return self:info(cerr, 3) end
    self:interactive(_("Pulling reading progress…"), function()
        local token, err = self:getToken()
        if not token then return err end
        local status, detail = self:doPullProgress(token, ctx, true)
        if not status then
            self:recordError("pull progress", detail)
            return _("Pull failed:") .. "\n" .. tostring(detail)
        elseif status == "none" then
            return _("No progress stored for this book."), 3
        elseif status == "moved" then
            local from = type(detail) == "table" and detail.device or nil
            return from and T(_("Moved to the position from %1."), from) or _("Moved to the synced position."), 3
        end
        return _("Already at the synced position."), 3
    end)
end

function GDrivePlus:syncVocabulary()
    self:interactive(_("Syncing vocabulary…"), function()
        local token, err = self:getToken()
        if not token then return err end
        local ok, msg = self:doSyncVocabulary(token)
        if not ok then
            self:recordError("vocabulary", msg)
            return _("Vocabulary sync failed:") .. "\n" .. tostring(msg)
        end
        return msg, 3
    end)
end

-- ---------------------------------------------------------------------------
-- Automatic sync on open / close
-- ---------------------------------------------------------------------------

--- @param closing true when called from onCloseDocument
function GDrivePlus:autoSync(closing)
    if not self:isConfigured() then return end
    local ctx = self:bookContext()
    if not ctx then return end
    if closing then
        -- Remember when this device last had the book open, even when offline or
        -- when the push fails, so an older position from elsewhere is never applied.
        ctx.cache.progress_ts = os.time()
        self:saveBookCache(ctx)
    end
    if not isConnected() then return end

    local ok, crash = xpcall(function()
        local token, err = self:getToken()
        if not token then
            self:recordError("token", err)
            return
        end
        if self.settings.auto_sync then
            local sok, res = self:doSyncAnnotations(token, ctx, closing)
            if not sok then
                self:recordError("annotation sync", res)
                if not closing then
                    self:info(_("Google Drive sync failed:") .. "\n" .. tostring(res), 5)
                end
            elseif not closing and res.pulled then
                self:info(_("Annotations from other devices were added."), 3)
            end
        end
        if self.settings.sync_progress then
            if closing then
                local pok, perr = self:doPushProgress(token, ctx)
                if not pok then self:recordError("push progress", perr) end
            else
                local status, detail = self:doPullProgress(token, ctx, false)
                if not status then
                    self:recordError("pull progress", detail)
                elseif status == "moved" then
                    local from = type(detail) == "table" and detail.device or nil
                    self:info(from and T(_("Moved to the position from %1."), from)
                        or _("Moved to the synced position."), 3)
                end
            end
        end
        if self.settings.sync_vocabulary then
            local vok, verr = self:doSyncVocabulary(token)
            if not vok then self:recordError("vocabulary", verr) end
        end
        if closing and self.settings.upload_statistics
            and os.time() - (tonumber(self.settings.statistics_uploaded_at) or 0) > STATS_INTERVAL then
            local sok, serr = self:doUploadStatistics(token)
            if not sok then self:recordError("statistics", serr) end
        end
    end, function(e)
        return tostring(e) .. "\n" .. debug.traceback()
    end)
    if not ok then self:recordError("auto sync", crash) end
end

--- Pull for the open book after `delay` seconds, or, when offline then, as soon
--- as Wi-Fi connects within PULL_WAIT (see onNetworkConnected).
function GDrivePlus:requestPull(delay)
    if not (self.settings.auto_sync or self.settings.sync_progress) then return end
    if not self:isConfigured() then return end
    self.pull_until = os.time() + PULL_WAIT
    UIManager:unschedule(self.pull_task)
    UIManager:scheduleIn(delay, self.pull_task)
end

function GDrivePlus:runPendingPull()
    if not self.pull_until then return end
    -- the book may have been closed again in the meantime
    if os.time() > self.pull_until or not (self.ui and self.ui.document) then
        self.pull_until = nil
        return
    end
    if not isConnected() then return end -- tried again on NetworkConnected
    self.pull_until = nil
    self:autoSync(false)
end

--- The book is being left for a while (sleep, app sent to the background, Wi-Fi
--- going off): push like on close. One sleep can send several of these events.
function GDrivePlus:pushOnLeave()
    if not (self.ui and self.ui.document) then return end
    -- this push covers pending change and position syncs; nobody reads in the meantime
    UIManager:unschedule(self.change_task)
    UIManager:unschedule(self.push_task)
    UIManager:unschedule(self.idle_task)
    self.idle_scheduled = false
    if not (self.settings.auto_sync or self.settings.sync_progress) then return end
    local now = os.time()
    if now - (self.left_at or 0) < LEAVE_PUSH_GAP then return end
    self.left_at = now
    self:autoSync(true)
end

function GDrivePlus:onReaderReady()
    self.reader_ready = true
    self.last_turn = os.time()
    self:scheduleIdlePull()
    self:requestPull(3)
end

function GDrivePlus:onCloseDocument()
    for _, task in ipairs({ self.change_task, self.pull_task, self.push_task, self.idle_task }) do
        UIManager:unschedule(task)
    end
    self.pull_until = nil
    self.reader_ready = false
    self.idle_scheduled = false
    if self.jump_dialog then
        UIManager:close(self.jump_dialog)
        self.jump_dialog = nil
    end
    if not (self.settings.auto_sync or self.settings.sync_progress) then return end
    self:autoSync(true)
end

-- The handlers below must not return true: these events are meant for every module.

--- Kobo, Kindle & co. switch Wi-Fi off when going to sleep, before Suspend is sent;
--- this is the last moment to push. Also sent when Wi-Fi is turned off by hand.
function GDrivePlus:onNetworkDisconnecting()
    self:pushOnLeave()
end

--- Sleep on devices that keep Wi-Fi on.
function GDrivePlus:onSuspend()
    self:pushOnLeave()
end

--- Android sends this when KOReader goes to the background or the screen turns off;
--- elsewhere it comes from the "Suspend" gesture action, ahead of the events above.
function GDrivePlus:onRequestSuspend()
    self:pushOnLeave()
end

function GDrivePlus:onResume()
    self.left_at = nil -- reading again: the next sleep must push, however soon
    if not (self.ui and self.ui.document) then return end
    self.last_turn = os.time()
    self:scheduleIdlePull()
    self:requestPull(3)
end

function GDrivePlus:onNetworkConnected()
    if self.pull_until then
        UIManager:unschedule(self.pull_task)
        UIManager:scheduleIn(2, self.pull_task)
    end
end

--- A highlight, note or bookmark was added, changed or removed: sync once the
--- reader has left the annotations alone for CHANGE_SYNC_DELAY seconds.
function GDrivePlus:onAnnotationsModified()
    if not (self.settings.auto_sync and self.settings.sync_on_change) then return end
    if not (self.ui and self.ui.document) or not self:isConfigured() then return end
    UIManager:unschedule(self.change_task)
    UIManager:scheduleIn(CHANGE_SYNC_DELAY, self.change_task)
end

--- Quiet annotation sync after a change. Only when already online: Wi-Fi is not
--- switched on for this, the next close or sleep pushes the change instead.
function GDrivePlus:syncChangedAnnotations()
    if not (self.ui and self.ui.document) or not isConnected() then return end
    local ctx = self:bookContext()
    if not ctx then return end
    self:quietly("annotation sync", function()
        local token, err = self:getToken()
        if not token then
            self:recordError("token", err)
            return
        end
        local sok, res = self:doSyncAnnotations(token, ctx, true)
        if not sok then
            self:recordError("annotation sync", res)
        elseif res.pulled then
            self:info(_("Annotations from other devices were added."), 3)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Reading progress while reading
-- ---------------------------------------------------------------------------

--- Background work while the user reads: short network timeouts, so a bad
--- connection cannot freeze the page for long; errors are only recorded.
function GDrivePlus:quietly(what, fn)
    network.short_timeouts = true
    local ok, err = runCaught(fn)
    network.short_timeouts = false
    if not ok then self:recordError(what, err) end
end

--- Seconds between position pushes while reading; 0 when switched off.
function GDrivePlus:progressInterval()
    if not self.settings.sync_progress then return 0 end
    return (tonumber(self.settings.progress_interval) or 0) * 60
end

function GDrivePlus:setProgressInterval(minutes)
    self.settings.progress_interval = minutes
    self:save()
    UIManager:unschedule(self.push_task)
    if minutes == 0 then
        UIManager:unschedule(self.idle_task)
        self.idle_scheduled = false
    elseif self.ui and self.ui.document then
        if self.progress_dirty then self:schedulePeriodicPush() end
        self:scheduleIdlePull()
    end
end

function GDrivePlus:onPageUpdate(page)
    self:positionChanged("page", page)
end

--- Scroll mode of reflowable books reports positions instead of pages.
function GDrivePlus:onPosUpdate(pos)
    self:positionChanged("pos", pos)
end

function GDrivePlus:positionChanged(kind, value)
    if value == nil then return end
    local key = "last_" .. kind
    if self[key] == value then return end
    local first = self[key] == nil
    self[key] = value
    -- the position the book opens at is not a page turn
    if first or not self.reader_ready then return end
    if self.applying_remote or os.time() - (self.remote_applied_at or 0) <= 2 then return end
    self.last_turn = os.time()
    self.progress_dirty = true
    self:schedulePeriodicPush()
    if not self.idle_scheduled then self:scheduleIdlePull() end
end

--- Push PUSH_QUIET seconds after the last page turn, while the reader reads
--- rather than touches the screen, and at most once per interval.
function GDrivePlus:schedulePeriodicPush()
    local interval = self:progressInterval()
    if interval == 0 then return end
    local wait = math.max(PUSH_QUIET, (self.last_push or 0) + interval - os.time())
    UIManager:unschedule(self.push_task)
    UIManager:scheduleIn(wait, self.push_task)
end

function GDrivePlus:runPeriodicPush()
    if not self.progress_dirty or not (self.ui and self.ui.document) then return end
    if self:progressInterval() == 0 or not self:isConfigured() then return end
    if not isConnected() then return end -- stays pending for the next page turn, sleep or close
    local ctx = self:bookContext()
    if not ctx then return end
    self.last_push = os.time() -- after a failure too: retry an interval later, not on every page
    self:quietly("push progress", function()
        local token, err = self:getToken()
        if not token then
            self:recordError("token", err)
            return
        end
        local ok, perr = self:doPushProgress(token, ctx)
        if not ok then self:recordError("push progress", perr) end
    end)
end

function GDrivePlus:scheduleIdlePull()
    local interval = self:progressInterval()
    UIManager:unschedule(self.idle_task)
    self.idle_scheduled = interval > 0 and self:isConfigured()
    if self.idle_scheduled then UIManager:scheduleIn(interval, self.idle_task) end
end

--- A book left open on one page (say, a phone on the table while reading on
--- another device) picks up a newer position from elsewhere every interval.
function GDrivePlus:runIdlePull()
    self.idle_scheduled = false
    if not (self.ui and self.ui.document) or self:progressInterval() == 0 then return end
    local idle = os.time() - (self.last_turn or 0)
    if idle > IDLE_PULL_LIMIT then return end -- resumes with the next page turn
    self:scheduleIdlePull()
    -- (an open question about jumping waits for its answer)
    if idle < IDLE_PULL_AFTER or self.progress_dirty or self.jump_dialog then return end
    if not self:isConfigured() or not isConnected() then return end
    local ctx = self:bookContext()
    if not ctx then return end
    self:quietly("pull progress", function()
        local token, err = self:getToken()
        if not token then
            self:recordError("token", err)
            return
        end
        local status, detail = self:doPullProgress(token, ctx, false)
        if not status then
            self:recordError("pull progress", detail)
        elseif status == "moved" then
            local from = type(detail) == "table" and detail.device or nil
            self:info(from and T(_("Moved to the position from %1."), from)
                or _("Moved to the synced position."), 3)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Browse and download
-- ---------------------------------------------------------------------------

function GDrivePlus:setDownloadDir()
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = true,
        select_file = false,
        path = self.settings.download_dir,
        onConfirm = function(path)
            self.settings.download_dir = path
            self:save()
            self:info(_("Download folder set to:") .. "\n" .. path, 3)
        end,
    })
end

function GDrivePlus:browse(folder_id, folder_name)
    self:interactive(_("Loading…"), function()
        local token, err = self:getToken()
        if not token then return err end
        local files, lerr = network.listFiles(token, folder_id)
        if not files then
            self:recordError("browse", lerr)
            return _("Cannot list folder:") .. "\n" .. tostring(lerr)
        end
        local items = {}
        if #self.history > 0 then
            table.insert(items, {
                text = _(".. [Back]"),
                callback = function()
                    local last = table.remove(self.history)
                    UIManager:close(self.current_menu)
                    self:browse(last.id, last.name)
                end,
            })
        end
        if not folder_id then
            -- Items other people shared are not inside "My Drive"; offer them separately.
            table.insert(items, {
                text = "▸ " .. _("Shared with me"),
                callback = function()
                    table.insert(self.history, { id = folder_id, name = folder_name })
                    UIManager:close(self.current_menu)
                    self:browse(network.SHARED_WITH_ME, _("Shared with me"))
                end,
            })
        end
        for _, file in ipairs(files) do
            local is_folder = file.mimeType == network.FOLDER_MIME
            table.insert(items, {
                text = (is_folder and "▸ " or "") .. file.name,
                callback = function()
                    if is_folder then
                        table.insert(self.history, { id = folder_id, name = folder_name })
                        UIManager:close(self.current_menu)
                        self:browse(file.id, file.name)
                    else
                        self:download(file)
                    end
                end,
            })
        end
        self.current_menu = Menu:new{
            title = folder_name or _("Google Drive"),
            item_table = items,
        }
        UIManager:show(self.current_menu)
        return nil
    end)
end

function GDrivePlus:download(file)
    local clean_name = file.name:gsub("[\\/]", "_")
    local dest_path = self.settings.download_dir .. "/" .. clean_name
    self:interactive(T(_("Downloading %1…"), file.name), function()
        local token, err = self:getToken()
        if not token then return err end
        local ok, derr = network.downloadToFile(token, file.id, dest_path)
        if not ok then
            self:recordError("download", derr)
            return _("Download failed:") .. "\n" .. tostring(derr)
        end
        return T(_("Saved to %1"), dest_path), 5
    end)
end

return GDrivePlus
