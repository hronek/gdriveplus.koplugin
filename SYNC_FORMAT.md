# Sync file format (version 2)

This is the contract between the KOReader plugin and the web reader. Both read
and write the same files in the user's Google Drive.

```
KOReader_Sync/
  annotations/<book file name>.json      e.g. "Moje kniha.pdf.json"
  progress/<book file name>.json
  vocabulary_builder.sqlite3             KOReader's vocabulary builder database
```

`<book file name>` is the name of the book file including its extension, without
any folder. The file name is the identity of a book: two files with the same
name share annotations.

Every file also carries the Drive property `appProperties.partial_md5` (visible
only to the same OAuth client). When a book is renamed, the old sync file is
found through that property and renamed.

All files are UTF-8 JSON that a browser's `JSON.parse` accepts: no `NaN`, no
`Infinity`, no `null` values (absent keys instead).

## annotations/*.json

```json
{
  "version": 2,
  "book": {
    "file": "Moje kniha.pdf",
    "title": "Moje kniha",
    "authors": "A. Autor",
    "partial_md5": "0123456789abcdef0123456789abcdef",
    "paging": true
  },
  "annotations": {
    "<key>": { "...": "one entry" }
  }
}
```

- `book.partial_md5` is KOReader's partial MD5 of the file content (1024-byte
  samples at offsets 0, 1024, 4096, … 1024·4^10).
- `book.paging` is `true` for fixed-layout books (PDF, DjVu, CBZ) and `false`
  for reflowable ones (EPUB, FB2, MOBI…). It decides the shape of positions.
- `annotations` is always an object, `{}` when empty.

### Entry

An entry is KOReader's annotation table, unchanged, plus an optional
`"deleted": true`.

| Field | Paging book (PDF) | Reflowable book (EPUB) |
|---|---|---|
| `page` | page number, 1-based | xpointer string (same as `pos0` for highlights) |
| `pos0`, `pos1` | `{x, y, page, zoom, rotation}` | xpointer strings |
| `pboxes` | `[{x, y, w, h}, …]`, one box per line | — |
| `ext` | multi-page highlights only: `{"<page>": {pos0, pos1, pboxes}}` | — |
| `epubcfi` | — | written by recent KOReader builds; informational |

Common fields: `text` (highlighted text), `note`, `chapter`, `pageno`,
`drawer` (`lighten` \| `underscore` \| `strikeout` \| `invert`), `color`
(`red`, `orange`, `yellow`, `green`, `olive`, `cyan`, `blue`, `purple`, `gray`),
`datetime`, `datetime_updated` — both `"YYYY-MM-DD HH:MM:SS"` in local time.

An entry without `pos0`/`pos1` is a page bookmark; it has no `drawer`.

KOReader draws a PDF highlight from `pos0` and `pos1` (it looks up the words at
those two points and everything between them), so they must lie inside the
first and the last highlighted word, and both need a numeric `page`. `pboxes`
is what KOReader computed at the time of highlighting; other readers draw from
it directly.

PDF coordinates are in page space at zoom 1: PDF points, origin at the top-left
corner of the page's crop box, y growing downwards. `zoom` and `rotation` only
record the view state at the time of highlighting; a writer that has no view
state uses `zoom: 1, rotation: 0`.

### Key

```
PDF highlight    p<page>|<x0>,<y0>|<x1>,<y1>     coordinates rounded half-up to integers
EPUB highlight   <pos0>|<pos1>
bookmark         BOOKMARK|<page>
```

Readers recompute the key from the entry and ignore the key stored in the file,
so a writer with a bug in its key cannot split an annotation in two. Entries
whose key cannot be computed are preserved under `?<original key>` and never
shown.

### Deleting

A deleted annotation stays in the file as a tombstone: the whole entry as it
was, plus `"deleted": true` and `datetime_updated` set to the time of
deletion. Tombstones are what makes a deletion on one device reach the
others; they are never removed. Because they keep colour, note and boxes, a
client can offer to restore a deleted annotation; a restore writes the entry
back without `deleted` and with a `datetime_updated` newer than the deletion.

Tombstones written by early development versions keep only `page`, `pos0`,
`pos1`, `text`, `chapter` and `datetime`; readers must accept both forms.

### Merge

Each client keeps a snapshot of the file as it was after its last successful
sync (the *base*). For every key, with `L` = local, `R` = remote, `B` = base:

1. Present in `B` and live there, missing locally → `L` is a new tombstone
   stamped with the current time.
2. Only one side has it → take that side.
3. `L` equals `R` → nothing to do.
4. `L` equals `B` (unchanged here) → take `R`.
5. `R` equals `B` (unchanged there) → take `L`.
6. Otherwise the larger `datetime_updated` (or `datetime`) wins; a tie goes to `L`.

Rules 4 and 5 mean that clock differences between devices only matter when the
same annotation was edited on both sides between two syncs.

`tests/fixtures/merge_cases.json` holds test cases both implementations run.

### What a writer must guarantee

- PDF highlight: numeric `page`, `pos0.x/y`, `pos1.x/y`, and a non-empty
  `pboxes`. The plugin fills in `zoom`, `rotation`, `pos.page`, `drawer` and
  `datetime` when they are missing.
- EPUB highlight: `page`, `pos0`, `pos1` are xpointers that exist in the book.
  The plugin checks every xpointer it did not create itself and skips entries
  that do not resolve.

Entries that fail these checks stay in the file but are not loaded into
KOReader, so a faulty writer cannot break the reader.

## progress/*.json

```json
{
  "version": 2,
  "book": { "file": "Moje kniha.pdf", "partial_md5": "…" },
  "progress": 42,
  "percentage": 0.3141,
  "pages": 134,
  "timestamp": 1794571200,
  "device": "Kobo_spaBW",
  "device_id": "6734d1c0a1b2c3"
}
```

- `progress`: page number for paging books, xpointer for reflowable ones. A
  writer that cannot produce an xpointer omits it; `percentage` (0–1) is used.
- `timestamp`: Unix time of the write. On opening a book a client jumps only
  when the file comes from another `device_id` and is newer than the last time
  the book was open on this client.

## Legacy files

The original gdrive.koplugin wrote `annotations/<partial_md5>.json` (a bare map
keyed `pos0|pos1`) and `progress/<partial_md5>_progress.json`. When no v2 file
exists, the annotation file is imported once and a v2 file is created next to
it; the legacy file is left untouched.
