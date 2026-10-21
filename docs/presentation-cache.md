# Tab presentation caches

Previews are disposable, profile-local JPEGs in `Cache/PagePreviews-v1/` beneath
SessionStore's data directory (including `CIO_DATA_DIR`). They are disabled when
session persistence is disabled. The snapshot schema remains compatible.

| Data | Bound | Eviction / lifetime |
| --- | --- | --- |
| Decoded previews | 15 entries and 8 MiB estimated RGBA cost | Reads and captures refresh LRU; negative hits count toward the entry limit |
| Disk previews | 100 files and 8 MiB; 64 KiB per image; longest edge 320 pixels | File modification times persist LRU reads across relaunches; both budgets enforced on load and before writes |
| Persisted tab favicons | 128 tabs and 4 MiB total; 64 KiB per icon | Retain the current tab then most recently activated tabs; titles, pins and split membership survive artwork eviction |
| Favicon raster | Longest edge 64 pixels, one PNG representation | Chromium images, fallback downloads and runtime restore use bounded raster artwork |
| Fallback favicon URL cache | 256 entries and 4 MiB | Read/write LRU; missing entries expire after five minutes and also consume slots |
| Favicon requests | 16 in flight, 1 MiB streamed input per request, eight-second request timeout | Shared URL requests deduplicate; additional views wait for a slot and can cancel |
| Titles | 4 KiB UTF-8 per tab | Kept with current tabs; Unicode-safe truncation; existing recently-closed stack remains capped at ten, with no separate title history cache |

Disk identity includes tab UUID and a SHA-256 digest of the exact committed URL,
including query and fragment. Startup drops entries that no longer belong to the
workspace. Navigation and accepted closes invalidate the tab's preview; a new
capture replaces its prior URL's file. Broken/oversize images become ordinary
cache misses and cannot prevent workspace restore. Files use mode 0600 inside
a mode-0700 directory. Failed deletion stays accounted for and cannot free a
fictional budget for more writes.

Filesystem operations run on a dedicated actor. Startup asynchronously warms
the five MRU presentation units (up to fifteen split panes), without creating
background browsers. Disk completions notify the switcher even if the read
started before it opened. Capture occurs after a visible page finishes loading,
before leaving its presentation, when showing the switcher, and before normal
termination. URL changes and capture/read tokens reject stale completions.
Normal termination drains captures and queued writes before Chromium closes;
a one-second operational deadline keeps an unresponsive compositor/cache from
holding quit indefinitely. Cache failures fall back to native placeholders.

Regression coverage:

- `PresentationCacheTests`: memory read LRU, byte/count limits, replacements,
  negative entries, Unicode title bounds and workspace/snapshot artwork budgets.
- `PagePreviewStoreTests`: new-instance restoration, exact URL matching, private
  files, persisted read recency, byte/count eviction, lower startup limits,
  corruption, replacement, invalidation and disabled/rejected writes.
- `TabFaviconCacheTests`: read LRU, missing-entry expiry/eviction, and waiting for
  a concurrency slot rather than dropping visible favicon requests.

Validation logs for this change: `/private/tmp/cio-artwork-model.log`,
`/private/tmp/cio-artwork-acceptance-build.log` and
`/private/tmp/cio-artwork-acceptance-xctest.log`.

Acceptance: 121 model tests and 246 native XCTest cases passed. The final
required Debug build and build-for-testing use the repository build script.

Control-arrow / smaller-preview follow-up:

- While a Control-Tab gesture is active, Left/Right changes only the highlight;
  release still commits once. Chromium's raw-key pre-handler synchronously offers
  Control-arrows to the flight's scoped observer, sharing its local AppKit handler.
  Without an active flight, or with Command/Option, the event is not consumed.
- The compositor now receives the image policy's 320-pixel limit directly. JPEG
  quality is 0.6 and encoded size is capped at 64 KiB; a square decoded preview
  uses at most 400 KiB of RGBA pixels (usual page aspect ratios use less).
- Earlier 512-pixel / larger JPEGs are resized on the storage actor while retaining
  their tab/URL identity. Oversize byte entries migrate on load, and smaller files
  with older pixel dimensions migrate when requested. Valid last-launch previews
  survive the policy change.
- `verify_tab_shortcuts.sh` also verifies active/inactive arrow dispatch, repeat,
  function/numeric-pad flags, modifiers, key-up and observer removal.
- The held-Control lifetime fix, production replay command and computer-use
  evidence are recorded in [recent-tab-input-validation.md](recent-tab-input-validation.md).
