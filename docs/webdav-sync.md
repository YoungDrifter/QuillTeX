# QuillTeX WebDAV sync contract (v1)

QuillTeX publishes a **read-only snapshot** of the document library to a WebDAV
folder. Uploads are manual (the Sync button in the tab bar); there is no timer
and no upload-on-build. The receiving app is a reader: it never writes to this
folder, and QuillTeX never imports remote changes.

## Remote layout

```text
<WebDAV root>/<remote folder>/v1/index.json
<WebDAV root>/<remote folder>/v1/blobs/<sha256>.pdf
```

The default remote folder is `QuillTeX`. For Nutstore the WebDAV root is
`https://dav.jianguoyun.com/dav/`, so the default index URL is:

```text
https://dav.jianguoyun.com/dav/QuillTeX/v1/index.json
```

Authentication is HTTP Basic with the Nutstore account e-mail and a
**third-party app password** (not the account login password).

## index.json

```json
{
  "schemaVersion": 1,
  "revision": 12,
  "generatedAt": "2026-11-22T05:00:00Z",
  "appVersion": "2.1.3 (163)",
  "folders": [
    {
      "id": "D8F6E3B4-…",
      "parentID": null,
      "name": "Papers",
      "color": "blue",
      "sortOrder": "manual"
    }
  ],
  "projects": [
    {
      "id": "1C2D3E4F-…",
      "displayName": "My Paper",
      "mainFileName": "main.tex",
      "kind": "project",
      "folderID": "D8F6E3B4-…",
      "folderPath": ["Papers", "2026"],
      "tags": ["ML"],
      "starred": true,
      "addedAt": "2026-11-01T09:00:00Z",
      "lastViewedAt": "2026-11-22T04:30:00Z",
      "updatedAt": "2026-11-22T04:20:00Z",
      "createdOnDiskAt": "2026-10-30T08:00:00Z",
      "pdf": {
        "blob": "blobs/2f6e…c1.pdf",
        "sha256": "2f6e…c1",
        "bytes": 842133
      }
    }
  ]
}
```

- All dates are ISO 8601.
- `revision` is a convenience counter, not a monotonic contract; it can restart
  if the sender's local sync state is removed. Use the index ETag/content to
  decide whether to reload.
- `pdf` is `null` when the project has no compiled PDF.
- A project that is no longer in `projects` has been removed from the library.
  Its old blob is deleted after the new index is uploaded.
- `blob` is relative to `v1/`; resolve it against the index URL.
- `folderPath` is an array of names. Folder names can contain characters that
  are illegal in a path, so do not join them into a local path.
- Absolute local paths, TeX source, images and bibliography files are **not**
  included.

## Reading algorithm

1. `GET v1/index.json` (or `PROPFIND` it first and only GET when it changed).
2. Parse `schemaVersion`. Reject an unknown, newer schema instead of guessing.
3. Build the folder tree from `folders` (`parentID`), then group `projects` by
   `folderID`.
4. For each non-null `pdf`, download `v1/<blob>` if it is not already cached.
   Verify the downloaded bytes against `sha256`; a mismatch means retry from
   step 1.
5. Cache PDFs by their SHA-256. A changed PDF always gets a new blob name.

The publisher is single-writer. Receivers should not write to this folder, and
there is no merge or conflict resolution in v1. WebDAV has no push channel;
poll `index.json` on launch/foreground (or at a modest interval) and download
only blobs whose hashes are new to the local cache.

## Incremental publishing

QuillTeX keeps a local `SyncState.json` beside `DocumentCatalog.json`:

- A PDF is re-hashed only when its size or modification date changed.
- A PDF blob is uploaded only when its SHA-256 is not already on the server.
- `index.json` is uploaded only when its stable content changes. The volatile
  `lastViewedAt` field is excluded from that comparison.
- After a new index is safely uploaded, blobs that are no longer referenced are
  deleted, so the remote folder holds one current PDF per project instead of
  every compiled version.

Receivers must therefore **re-read the index before downloading a blob**. A
cached old index can reference a blob that was just removed. If a blob request
returns 404, re-fetch the index and try again.

## Limits

Nutstore documents a 500 MB single-file limit, 600 WebDAV requests per 30
minutes on free accounts (1500 on paid), and 750 entries per PROPFIND request.
QuillTeX only issues `PROPFIND Depth: 0` for existence checks, so it never
needs to page a directory listing.
