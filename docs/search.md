# Indexing and search

The save folder was write-only in practice: Finder can't see inside a PNG, so
"that Immich settings page from last week" meant scrolling a grid of
thumbnails. QuickSnap already reads text off screen on demand; doing it at
save time and keeping the result turns the folder into an archive.

- `Services/CaptureIndex.swift` — the store (SQLite FTS5).
- `Coordinators/CaptureIndexer.swift` — keeps the store in step with the
  folder: index-on-save, backfill, reconcile.
- `Coordinators/CaptureSearchController.swift` + `Views/Search/` — the panel.
- Settings → Intelligence → Search.

## The store

**SQLite FTS5 through the system `libsqlite3`** — `import SQLite3`, no
package, no dependency. macOS ships FTS5 compiled in (verified from Swift
against the SDK's own library before any of this was written). A JSON file
re-read and re-scanned per keystroke was the alternative; it gives up ranking
and falls over once a folder has a few thousand captures.

One virtual table, with the metadata columns marked `UNINDEXED` so they ride
along without being searchable:

```sql
CREATE VIRTUAL TABLE captures USING fts5(
    name, app, window, caption, transcript,
    path UNINDEXED, modified UNINDEXED,
    tokenize = 'unicode61 remove_diacritics 2'
);
```

Column order is load-bearing twice: `bm25` takes one weight per column in
this order, and `snippet` takes a column index. Weights are
`8, 4, 4, 6, 1, 0, 0` — the name and the caption say what a capture *is*,
while the transcript is everything that happened to be on screen, so a stray
word in it shouldn't outrank a capture actually named for the thing.

**The database lives in Application Support, not the save folder.** It's
derived data QuickSnap can rebuild at any time; the save folder belongs to
the user, who may well sync it.

`CaptureIndex` is an `actor` rather than the usual stateless enum, because it
owns a database connection — exactly the mutable state Services normally
avoid. Actor isolation is what makes that connection safe to use from the
capture path, the backfill and the search field at once.

### Query building is a whitelist

`matchExpression(for:)` splits on anything that isn't a letter or digit,
lowercases, quotes each term and appends `*`, then ANDs them. Blunt on
purpose: no part of what the user typed can reach FTS5's own query syntax,
where a stray `"` or `*` is a syntax error and `NOT`/`NEAR` would quietly
change the search. Prefix matching means results appear while typing a word;
ANDing means more words narrow, which is what a search field is expected to
do.

## Keeping up with the folder

Three things move captures around, and all three are handled:

| Event | What happens |
| --- | --- |
| A capture is saved | Indexed from the same `CaptureAnalyzer` pass `{describe}` uses |
| `{describe}` renames it | `CaptureIndex.move` follows the file |
| Retention trashes files | `SaveFolderCleaner.clean` returns the URLs it deleted; the caller drops those rows |
| The user moves or deletes files in Finder | Reconciled at launch, and self-healed at query time |

That last one matters most: **a hit that opens nothing is worse than no
hit.** `search` checks each row's file exists, drops the ones that don't from
the results *and* deletes them, so the index heals as it's used rather than
only when a reconcile runs.

**Only files QuickSnap tagged are ever read** — everything goes through
`CaptureLibrary`, which filters on the `FileTag` xattr. The save folder is
user-chosen and may contain files that are not ours to read, let alone
transcribe into a database.

### Backfill

On first launch after the feature lands (and after "Rebuild"), the folder is
walked and everything already in it is indexed. Background priority, one file
at a time, cancellable from Settings; the "done" marker is only set when the
walk actually finishes, so stopping and coming back resumes rather than
restarts. Files whose modification date matches what was indexed are skipped.

Backfilled rows have no app or window — those aren't recoverable from the
file. The transcript is what makes them findable and that's the part that
matters. Note this applies after every "Rebuild" too, not just the first
walk: rebuilding trades the app and window of every on-save row for fresh
captions.

The fix, if that ever matters, is to write the app, window and capture date
into an extended attribute beside `FileTag` at save time, so the file
carries its own provenance and a rebuild recovers it. Considered and
deliberately deferred (2026-08-01): it only helps captures taken after it
ships, and the transcript already carries most of what makes a capture
findable.

This is OCR over every capture the user has ever taken, which is the one
genuinely expensive thing here. It's the trade the issue asked for: a folder
that is searchable from the moment the feature exists, rather than only for
captures taken afterwards.

## The panel

Spotlight-shaped: borderless, centered in the upper third, opened from the
menu bar or ⌘⇧2 (`HotkeyAction.searchCaptures`). Return reveals in Finder,
⌘Return opens the capture for markup, Esc closes, clicking away closes.

Two decisions worth keeping:

- **It takes key status, unlike every other panel in the app.** The preview
  panel and the toast go out of their way *not* to (`canBecomeKey == false`)
  so they never steal focus; a search box that can't be typed into is
  nothing, so this one overrides `canBecomeKey` to true and activates the
  app. No activation-policy change is needed — an accessory app can be
  frontmost without gaining a Dock icon, which is what keeps it feeling like
  a HUD rather than an app window.
- **Keyboard handling uses zero-sized `Button`s with `keyboardShortcut`,
  not `onKeyPress`.** Shortcuts resolve through `performKeyEquivalent`,
  which runs *before* the focused text field's editor sees the key — so ↑/↓
  move the selection instead of the insertion point, and ⌘↩ is never
  swallowed. Plain ↩ goes through `onSubmit`, the field's own idiom.

An empty query lists the most recent captures rather than showing nothing:
the panel is a way into the save folder, and "the one I just took" is the
most common thing being looked for.

## Verifying

`CaptureIndex.swift` depends only on Foundation and SQLite3, so it compiles
and runs standalone — schema, ranking, rename-following, reconcile and the
injection-hostile query cases are all exercisable without the app:

```
swiftc -O -parse-as-library CaptureIndex.swift indexmain.swift -o indextest
HOME=$PWD/testhome ./indextest
```

Override `HOME`: the database path is derived from the home directory, and a
running QuickSnap holds that file open — the test otherwise fails with
`database is locked`, which is the app working correctly, not a bug.
