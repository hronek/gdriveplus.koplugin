# Changelog

Each version's section is used as the text of its GitHub release. Changes not
released yet go under `## Unreleased`; `release.cmd` turns that into the next
version.

## 1.2.0 — 2026-11-19

### Added

- **Library sync: every book in the home folder, not only the open one.**
  Books read on another device or in the web reader get their annotations
  and reading position here without being opened. A book never opened on
  this device gets its metadata (`.sdr`) and appears in the history, so the
  file browser shows its progress and annotation viewers (such as
  annotationsviewer.koplugin) list its highlights. The other way round,
  what changed in a closed book here (a note edited in an annotation viewer,
  a position not pushed because Wi-Fi was off) goes to Drive.
  *Sync library* in the menu syncs everything at once. Automatically
  (*Settings → Sync the whole library automatically*, on by default) it runs
  in the file browser when KOReader starts, after a book is closed and on
  waking up, when Wi-Fi is on, at most every 10 minutes, for up to 25 books
  at a time, one book after the other so the file browser stays usable.
  When nothing changed it costs two small requests.

### Fixed

- A remote annotation that a device could not show (its position not found
  in that device's copy of the book, or a broken entry) was deleted for all
  devices at that device's next sync. It now stays on Drive.
- Closing a book in which an annotation had ever been deleted always made a
  sync request, even when nothing had changed.

## 1.1.1 — 2026-11-16

- Fixed: turning to the second page of *Settings* crashed KOReader (1.1.0,
  on all devices). The new *Version* item called a function that KOReader
  replaces with the version text from the plugin's `_meta.lua`.
- A menu item whose text cannot be made now shows "?" and records the error
  under *Show last error* instead of crashing KOReader.

## 1.1.0 — 2026-11-16

- **Syncs while you read.** The reading position is pushed every 2 minutes
  (*Settings → Sync reading progress while reading*: 2, 5, 10, 15, 30 minutes,
  1 hour or off), 10 s after a page turn, while you read rather than touch the
  screen. Requests made while reading give up after 10 s on a bad connection.
- **A book left open picks up the position from elsewhere.** After 2 minutes
  on the same page it checks every interval for a newer position from another
  device, for up to 2 hours.
- **Sync on sleep and wake**, and on Android when KOReader goes to the
  background and comes back. On Kobo, Kindle and similar the push happens just
  before Wi-Fi is switched off. If Wi-Fi is off on opening or waking, the pull
  follows as soon as it connects.
- **Annotations sync 20 s after a change** (new or edited highlight, note or
  bookmark) when online; can be switched off.
- **Asks before taking over a position from another device**, showing the
  device, when it was saved, and both positions (page, percentage, chapter).
  *Stay here* is not asked again for that position. Can be switched off.
- **Two new options for which positions are offered**, both on: only
  positions saved after your last reading here (offline reading counts), and
  only positions further on in the book.
- **Device name** in *Settings*: how your other devices and the web reader's
  statistics call this device. Empty means the model name.
- **Version shown** at the bottom of *Settings*.
- An expired refresh token now explains how to fix it for good (put the Google
  app in production); the README setup guide has a step for that.

## 1.0.1 — 2026-11-14

- Fixed: *Load refresh token* crashed KOReader when the original
  gdrive.koplugin was (or had been, without a restart) installed. Its modules
  shadowed ours; all helper modules now have unique `gdriveplus_` names.
- Loading `client_id.json` / `refresh_token.txt` shows any error instead of
  crashing, and says when the token file is unreadable or empty.
- Credential files are looked for in `koreader/gdriveplus/` only, no longer in
  the original plugin's `gdrive/` folder.
- Reading statistics are uploaded per device for the web reader (on closing a
  book, at most twice a day; *Upload reading statistics* in the menu).
- A deleted annotation keeps its whole entry, so it can be restored as it was.
- KOReader's highlight cache is cleared after a sync, file transfers have
  their own timeouts, and the last-seen time is recorded when closing offline.

## 1.0.0 — 2026-11-13

First release as Google Drive Plus, a fork of
[moohaad/gdrive.koplugin](https://github.com/moohaad/gdrive.koplugin): sync
files named after the book, working PDF sync, errors shown and logged,
nothing overwritten blindly, cached folder and file ids, shared content in the
Drive browser, and a documented, tested sync format.
