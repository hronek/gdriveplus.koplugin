# Google Drive Plus for KOReader

Two-way sync of highlights, notes, bookmarks, reading progress and vocabulary
between KOReader devices through your own Google Drive — and with the
[web reader](https://webkoreadergdrive.hronek.workers.dev), which opens the same
books and annotations in a browser.

This is a fork of [moohaad/gdrive.koplugin](https://github.com/moohaad/gdrive.koplugin).

## What is different from the original

- **Sync files are named after the book** (`Moje kniha.pdf.json`) instead of a
  hash. The hash is stored inside the file.
- **PDF sync works.** The merge no longer calls into the PDF engine, highlights
  on different pages can no longer overwrite each other, and multi-page
  highlights survive a sync.
- **Errors are shown and logged.** A failed sync says why; the last error is
  kept under *Settings → Show last error* and in `crash.log`.
- **Nothing is overwritten blindly.** If the file on Drive cannot be downloaded
  or read, the sync stops instead of replacing it.
- **Faster open/close.** Folder and file ids are cached, and closing a book
  with no new annotations makes no annotation request at all.
- **Syncs while you read**, not only when a book is opened or closed: the
  position every few minutes, annotations shortly after each change, and
  everything on sleep and wake.
- Reading progress only jumps to a *newer* position from *another* device, and
  asks first: it shows which device saved it and when, and where you are now
  against where you would go (page, percentage, chapter).
- Browsing reaches shared content: a *Shared with me* entry, shortcuts are
  followed, and shared drives are supported.
- Timeouts on every request, proper URL encoding, folders with more than 100
  files, downloads streamed to disk.
- The file format is documented in [SYNC_FORMAT.md](SYNC_FORMAT.md) and covered
  by tests.

Existing data is picked up: credentials are taken over from the original
plugin's settings, and annotation files it uploaded are imported on the first
sync of each book. Both plugins can be installed side by side, but only one
should have automatic sync enabled.

## Install

**From Storefront or App Store** (inside KOReader): search for
`gdriveplus.koplugin`.

**Manually**: download `gdriveplus.koplugin.zip` from
[Releases](../../releases), unzip it, and copy the `gdriveplus.koplugin` folder
into KOReader's `plugins` folder:

| Device | Folder |
|---|---|
| Kindle | `/mnt/us/koreader/plugins/` |
| Kobo | `/mnt/onboard/.adds/koreader/plugins/` |
| Android | `koreader/plugins/` on internal storage |

Restart KOReader. The plugin is under **Tools → Google Drive Plus**.

**Updating**: delete the old `gdriveplus.koplugin` folder, copy in the new
one and restart KOReader. Nothing has to be set up again: the credentials,
the download folder and all options are stored in KOReader's own settings
(`settings.reader.lua`), not in the plugin folder. The per-book sync state is
kept with the book's own metadata (normally its `.sdr` folder).

## Set up Google access

You need two files: `client_id.json` and `refresh_token.txt`. If you already
set up the original plugin, skip this — its credentials are reused.

> **Put the Google app in production (step 3).** While it is in *Testing*,
> Google lets the refresh token expire after **7 days**, and you would have to
> make a new one every week. In production it keeps working; it only stops if
> it is unused for six months or you revoke the access.

1. In [Google Cloud Console](https://console.cloud.google.com/) create a
   project and enable the **Google Drive API**.
2. Open **Google Auth Platform** (older consoles: *APIs & Services → OAuth
   consent screen*) and press *Get started*: an app name, your e-mail,
   audience **External**, a contact e-mail, *Create*.
3. **Switch to production:** *Audience → Publishing status → **Publish app** →
   Confirm*. The status changes to *In production*. Google does not need to
   verify the app for personal use: an unverified app works for up to 100
   users, it just shows a warning when you sign in (step 6).
4. Under **Clients** (older consoles: *APIs & Services → Credentials*) create
   an **OAuth client ID** of type **Web application** with the redirect URI
   `https://developers.google.com/oauthplayground`. Download the JSON and name
   it `client_id.json`.
5. Open the [OAuth Playground](https://developers.google.com/oauthplayground),
   click the gear icon, tick *Use your own OAuth credentials* and paste the
   client ID and secret.
6. Select the scope `https://www.googleapis.com/auth/drive` and authorise. On
   *Google hasn't verified this app* click *Advanced → Go to … (unsafe)*: it is
   your own app. Press *Exchange authorization code for tokens* and save the
   **refresh token** into `refresh_token.txt`.
7. Copy both files into a `gdriveplus` folder inside KOReader's folder
   (for example `/mnt/onboard/.adds/koreader/gdriveplus/`). The original
   plugin's `gdrive` folder is not searched; move the files from there.
8. In KOReader: *Google Drive Plus → Settings → Load client ID* and
   *Load refresh token*.

The same two files work on all your devices; there is no need to make a token
per device. They give full access to your Google Drive. Keep them private.

**Made the token while the app was still in Testing?** It expires 7 days
after it was made, even after the app is published. Publish the app (step 3),
make a new token (steps 5–6) and *Load refresh token* again on each device.

## Use

| Menu item | What it does |
|---|---|
| Sync this book now | Merges annotations with Drive and pushes the reading position |
| Push / Pull reading progress | Explicit one-way sync of the position |
| Sync vocabulary | Newest copy of the vocabulary builder database wins |
| Upload reading statistics | Copies this device's reading statistics to `KOReader_Sync/statistics/<device>.sqlite3`, where the web reader shows them together with its own |
| Browse Google Drive | Download books to the device — from My Drive, *Shared with me*, shortcuts to shared folders and shared drives |

*Sync this book now* is also available as a gesture action.

*Settings → Device name* sets what your other devices call this one when they
offer to jump to the position you left, and the name of its reading statistics
in the web reader. Empty means the model name (for example `Kobo_spaBW`).

### When it syncs automatically

| When | What |
|---|---|
| A book is opened (after 3 s), the device wakes up, or KOReader comes back from the background (Android) | Annotations are merged with Drive, a newer position from another device is offered, vocabulary is synced |
| A book is closed, the device goes to sleep, KOReader goes to the background (Android), or Wi-Fi is turned off | Annotations are pushed if they changed, the position is pushed, vocabulary is synced; statistics are uploaded at most twice a day |
| 20 s after the last new or changed highlight, note or bookmark | Annotations are merged with Drive |
| While reading, every 2 minutes (*Settings → Sync reading progress while reading*: 2, 5, 10, 15, 30 minutes, 1 hour or off) | The position is pushed 10 s after a page turn, while you read rather than touch the screen |
| A book stays open on the same page for 2 minutes or more | Every interval it checks for a newer position from another device and offers to jump there; it stops after 2 hours without a page turn |

Before jumping to a position from another device, a dialog shows the device,
when the position was saved, and both positions (page, percentage, chapter):
*Go there* or *Stay here*. *Stay here* is not asked again for that position,
only for a newer one. To jump without asking, turn off *Settings → Ask before
jumping to a position from another device*. *Pull reading progress* in the
menu always jumps without asking.

Each part can be switched off under *Settings*. Automatic sync never turns
Wi-Fi on. If Wi-Fi is off when a book is opened or the device wakes up, the
pull happens as soon as Wi-Fi connects (within 5 minutes). A push that could
not be done is done at the next close or sleep with Wi-Fi on.

KOReader runs requests in the same thread as the screen, so each one stops it
for a moment. That is why the position is not sent on every page. Instead it
is sent in one small request at most once per interval, at a moment without
page turns. Requests made while you read give up after 10 seconds on a bad
connection. Dictionary lookups do not sync on their own: the vocabulary is a
whole database file, uploaded at close or sleep.

## Troubleshooting

- **"Cannot get access token … invalid_grant"** — the refresh token expired or
  was revoked. Most often the app is still in *Testing* (7-day tokens): check
  that it is *In production* (step 3), then make a new token (steps 5–6) and
  load it again.
- **Any other failure** — *Settings → Show last error* shows the reason. The
  full details, including a stack trace for internal errors, are in KOReader's
  `crash.log` on lines starting with `GDrivePlus:`.
- **A folder was deleted on Drive** — *Settings → Forget cached Drive folders*.

## Development

The merge logic, JSON encoder and Drive workflow have no KOReader dependencies
and are tested on a PC:

```
luajit tests/test_core.lua
luajit tests/test_sync.lua
```

To release: bump `version` in `_meta.lua`, commit, and push a matching tag
(`v1.0.1`). The workflow runs the tests and attaches `gdriveplus.koplugin.zip`
to a GitHub Release, which is what Storefront and App Store install.

## Support

If the plugin is useful to you, you can support its development at
[paypal.me/hronekjiri](https://paypal.me/hronekjiri).

## Licence

MIT. Original work © 2025 moohaad; changes © 2026 Jiri Hronek.
