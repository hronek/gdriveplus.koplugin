# Google Drive Plus for KOReader

Two-way sync of highlights, notes, bookmarks, reading progress and vocabulary
between KOReader devices through your own Google Drive — and with the
[web reader](https://github.com/hronek/webKOReaderGdrive), which opens the same
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
- Reading progress only jumps to a *newer* position from *another* device.
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

## Set up Google access

You need two files: `client_id.json` and `refresh_token.txt`. If you already
set up the original plugin, skip this — its credentials are reused.

1. In [Google Cloud Console](https://console.cloud.google.com/) create a
   project and enable the **Google Drive API**.
2. Under *APIs & Services → OAuth consent screen* create an *External* app and
   add yourself as a test user. Then press **Publish app**: while the app is in
   *Testing* status Google expires refresh tokens after 7 days. A published,
   unverified app shows a warning screen once when you sign in; that is fine
   for personal use.
3. Under *Credentials* create an **OAuth client ID** of type **Web
   application** with the redirect URI
   `https://developers.google.com/oauthplayground`. Download the JSON and name
   it `client_id.json`.
4. Open the [OAuth Playground](https://developers.google.com/oauthplayground),
   click the gear icon, tick *Use your own OAuth credentials* and paste the
   client ID and secret.
5. Select the scope `https://www.googleapis.com/auth/drive`, authorise, press
   *Exchange authorization code for tokens*, and save the **refresh token**
   into `refresh_token.txt`.
6. Copy both files into a `gdriveplus` folder inside KOReader's folder
   (for example `/mnt/onboard/.adds/koreader/gdriveplus/`).
7. In KOReader: *Google Drive Plus → Settings → Load client ID* and
   *Load refresh token*.

The two files give full access to your Google Drive. Keep them private.

## Use

| Menu item | What it does |
|---|---|
| Sync this book now | Merges annotations with Drive and pushes the reading position |
| Push / Pull reading progress | Explicit one-way sync of the position |
| Sync vocabulary | Newest copy of the vocabulary builder database wins |
| Upload reading statistics | Copies this device's reading statistics to `KOReader_Sync/statistics/<device>.sqlite3`, where the web reader shows them together with its own |
| Browse Google Drive | Download books to the device — from My Drive, *Shared with me*, shortcuts to shared folders and shared drives |

With the default settings everything happens automatically when a book is
opened (after 3 seconds) and closed, if Wi-Fi is on; the statistics are
uploaded on closing a book at most twice a day. *Sync this book now* is also
available as a gesture action.

## Troubleshooting

- **"Cannot get access token … invalid_grant"** — the refresh token expired or
  was revoked. Create a new one (step 4–5); see step 2 about *Testing* status.
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
