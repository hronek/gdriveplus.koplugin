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

local network = require("network")
local progress = require("progress")
local sync = require("sync")
local utils = require("utils")

local SETTINGS_KEY = "gdriveplus"
local LEGACY_SETTINGS_KEY = "gdrive" -- settings of the original gdrive.koplugin
local SYNC_FOLDER = "KOReader_Sync"
local VOCAB_NAME = "vocabulary_builder.sqlite3"

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
    auto_sync = true,       -- sync annotations when a book is opened/closed
    sync_progress = true,   -- pull progress on open, push on close
    sync_vocabulary = true, -- include the vocabulary builder database
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
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function GDrivePlus:save()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
    if G_reader_settings.flush then G_reader_settings:flush() end
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

function GDrivePlus:addToMainMenu(menu_items)
    menu_items.gdriveplus = {
        text = _("Google Drive Plus"),
        sorting_hint = "tools",
        sub_item_table = {
            { text = _("Sync this book now"), callback = function() self:syncNow() end },
            { text = _("Push reading progress"), callback = function() self:pushProgress(true) end },
            { text = _("Pull reading progress"), callback = function() self:pullProgress(true) end },
            { text = _("Sync vocabulary"), callback = function() self:syncVocabulary(true) end,
              separator = true },
            { text = _("Browse Google Drive"), callback = function() self.history = {}; self:browse() end,
              separator = true },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text = _("Sync annotations on open/close"),
                        checked_func = function() return self.settings.auto_sync end,
                        callback = function() self:toggle("auto_sync") end,
                    },
                    {
                        text = _("Sync reading progress on open/close"),
                        checked_func = function() return self.settings.sync_progress end,
                        callback = function() self:toggle("sync_progress") end,
                    },
                    {
                        text = _("Sync vocabulary on open/close"),
                        checked_func = function() return self.settings.sync_vocabulary end,
                        callback = function() self:toggle("sync_vocabulary") end,
                        separator = true,
                    },
                    { text = _("Load client ID (client_id.json)"), callback = function() self:loadClientIDFromJson() end },
                    { text = _("Load refresh token (refresh_token.txt)"), callback = function() self:loadRefreshTokenFromFile() end },
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

--- Run `fn` with a "working…" message, after making sure we are online.
--- `fn` returns the text to show afterwards (or nil for nothing) and a timeout.
function GDrivePlus:interactive(title, fn)
    local function work()
        local msg = InfoMessage:new{ text = title }
        UIManager:show(msg)
        UIManager:forceRePaint()
        local ok, text, timeout = xpcall(fn, function(e)
            return tostring(e) .. "\n" .. debug.traceback()
        end)
        UIManager:close(msg)
        if not ok then
            self:recordError(title, text)
            self:info(_("Unexpected error:") .. "\n" .. tostring(text):match("^[^\n]*"))
        elseif text then
            self:info(text, timeout)
        end
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

--- Places where client_id.json / refresh_token.txt are looked for.
function GDrivePlus:credentialPaths(filename)
    local paths = {}
    local base = DataStorage:getFullDataDir() or DataStorage:getDataDir()
    local plugin_dir = self:getPluginDir()
    local ko_dir = plugin_dir:match("^(.*[/\\])plugins[/\\]")
    for _, folder in ipairs({ "gdriveplus", "gdrive" }) do
        table.insert(paths, base .. "/" .. folder .. "/" .. filename)
        if ko_dir then table.insert(paths, ko_dir .. folder .. "/" .. filename) end
    end
    table.insert(paths, plugin_dir .. filename)
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
    if content then
        self.settings.refresh_token = (content:gsub("%s+", ""))
        self.settings.access_token = ""
        self.settings.token_expiry = 0
        self:save()
        self:info(_("Refresh token loaded."), 3)
    end
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
            hint = "\n" .. _("The refresh token is no longer valid. Create a new one (tokens of OAuth apps in \"Testing\" status expire after 7 days).")
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
    local Device = require("device")
    return {
        ui = ui,
        paging = paging,
        sdr_dir = sdr_dir,
        remote_name = name .. ".json",
        cache = cache,
        device = Device.model or "KOReader",
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
    return ok, perr
end

function GDrivePlus:doPullProgress(token, ctx, force)
    local folder_id, err = self:getFolder(token, "progress")
    if not folder_id then return nil, err end
    ctx.folder_id = folder_id
    local status, detail = progress.pull(network, token, ctx, force)
    self:saveBookCache(ctx)
    return status, detail
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

-- ---------------------------------------------------------------------------
-- Menu actions
-- ---------------------------------------------------------------------------

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
    end, function(e)
        return tostring(e) .. "\n" .. debug.traceback()
    end)
    if not ok then self:recordError("auto sync", crash) end
end

function GDrivePlus:onReaderReady()
    if not (self.settings.auto_sync or self.settings.sync_progress) then return end
    if not self:isConfigured() then return end
    UIManager:scheduleIn(3, function()
        -- the book may have been closed again in the meantime
        if self.ui and self.ui.document then self:autoSync(false) end
    end)
end

function GDrivePlus:onCloseDocument()
    if not (self.settings.auto_sync or self.settings.sync_progress) then return end
    self:autoSync(true)
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
