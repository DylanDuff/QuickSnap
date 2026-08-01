# Uploading

Pushes captures to a remote destination. One provider is active at a time,
chosen in Settings → Uploading.

## Architecture

The feature is provider-agnostic end to end. Everything outside `Services/`
sees only the protocol:

```
Views/Settings/UploadingSettingsView.swift   provider picker + per-provider sections
Coordinators/UploadCoordinator.swift         lifecycle, toasts, concurrency
Services/UploadDestination.swift             protocol + UploadRequest/UploadOutcome
Services/ImmichDestination.swift             ─┐ conformers
Services/S3Destination.swift                 ─┘
Services/ImmichClient.swift                  pure REST layer for Immich
Services/AWSSignatureV4.swift                request signing for S3
Services/KeychainStore.swift                 secrets (never UserDefaults)
```

```swift
nonisolated protocol UploadDestination: Sendable {
    var providerName: String { get }
    func upload(_ request: UploadRequest) async throws -> UploadOutcome
}
```

**Adding a provider** means: a conformer in `Services/`, a case in
`UploadProvider`, a settings section subview, and a branch in
`AppSettings.uploadDestination`. Nothing in `UploadCoordinator`,
`CaptureCoordinator`, the preview panel, or the markup toolbar changes —
they only ever hold an `any UploadDestination`.

`AppSettings.uploadDestination` is the single place providers get built from
settings, and returns nil whenever uploading is off or the selected provider
is missing something it needs.

### Settings key layout

Provider-neutral keys are unprefixed (`uploadingEnabled`, `uploadProvider`,
`uploadAfterCapture`, `uploadCopiesLink`, `uploadShowsPreviewButton`); each
provider's own configuration stays prefixed (`immich*`, `s3*`). Secrets are
**never** in UserDefaults — the Immich API key and the S3 secret access key
live in the Keychain under `KeychainStore.Account`.

`uploadCopiesLink` means different work per provider: Immich mints a *new
public shared link*; S3 just returns the object's existing URL. The settings
label changes to say which.

## Feedback

Uploads have no other visible result, so `UploadCoordinator` reports through
a toast:

1. An **in-progress** pill shown with `autoDismisses: false` (added to
   `ToastController` for this) — an upload has no known duration, and the
   normal ~2 s timeout would make it vanish mid-transfer.
2. A **result** pill replacing it, with the link or provider detail as the
   second line.

Concurrent uploads (rapid captures) are reference counted via
`activeUploads`; only the last one to finish reports, so a fast upload's
result can't replace the in-progress pill for uploads still running.

## Triggers

Three, all settings-driven:

- **Automatic after capture** — `AppSettings.uploadsAfterCapture`, fired
  from `CaptureCoordinator.finish`.
- **Preview panel button** — `AppSettings.uploadShowsPreviewButton`.
  Deliberately hidden while automatic uploading is on (the capture has
  already been sent, so the button could only duplicate it), which is why
  the toggle is disabled in that state.
- **Markup toolbar button** — `AppSettings.Keys.markupShowsUploadButton`,
  uploading the *flattened* annotated image as `"<original> Annotated.png"`.

Both button toggles live on the Uploading page rather than Markup, so all
upload configuration is in one place. The markup upload button is
deliberately outside `MarkupSettingsView`'s "at least one output button
stays on" invariant — that rule guarantees a *local* export path always
remains, and a button that depends on a reachable server can't satisfy it.

---

# Immich

## There are no folders — the destination is an album

The single most important thing to know before extending this, and not
obvious from Immich's UI (which *does* show a Folders view).

Verified against the Immich OpenAPI spec (`3.1.0`):

- **`POST /api/assets`** takes `assetData`, `fileCreatedAt`,
  `fileModifiedAt` (required), plus `filename`, `isFavorite`, `visibility`,
  `duration`, `livePhotoVideoId`, `sidecarData`, `metadata`. **There is no
  folder or path field.**
- Immich's Folders view (`GET /api/view/folder?path=`) is **read-only**. It
  browses by `originalPath`, which the *server* assigns from its
  admin-configured storage template. A client cannot influence where a file
  lands on disk.
- The only grouping a client controls is the **album** —
  `POST /api/albums` and `PUT /api/albums/{id}/assets`.

If a future requirement really needs folder placement, the only lever is the
server's storage template (an admin setting), not anything QuickSnap can
send. Pull the spec directly rather than trusting secondhand docs:

```
curl -sSL https://raw.githubusercontent.com/immich-app/immich/main/open-api/immich-openapi-specs.json
```

## Endpoints used

All `x-api-key`-authenticated against the instance's `/api` base.

| Purpose | Call |
| --- | --- |
| Test connection | `GET /api/users/me` |
| List albums | `GET /api/albums` |
| Create album | `POST /api/albums` |
| Upload | `POST /api/assets` (multipart) |
| File into album | `PUT /api/albums/{id}/assets` |
| Shareable link | `POST /api/shared-links` |

A shared link's public URL is `https://<server>/share/<key>` — built off the
web root, not the `/api` base, which is why `ImmichCredentials` stores the
root and derives `apiBaseURL` from it.

### Upload response is not always "created"

`POST /api/assets` returns `status: "created"` **or** `"duplicate"` — Immich
dedupes by checksum, so re-uploading the same screenshot returns the existing
asset id. `UploadOutcome.isDuplicate` carries that through and the toast says
"Already in Immich" rather than claiming a fresh upload.

### Legacy device fields

`deviceAssetId`/`deviceId` are sent even though the current schema doesn't
list them. Immich validates with Zod (`nestjs-zod`), and the upload schema is
a plain non-strict `z.object`, so unknown keys are **stripped, not
rejected** — sending them costs nothing and keeps older servers (which
required them) working.

## API key permissions

Created under Account Settings → API Keys:

| Feature | Permission |
| --- | --- |
| Uploading at all | `asset.upload` |
| Album picker | `album.read` |
| New Album… | `album.write` |
| Shareable links | `sharedLink.create` |
| Test connection | `user.read` |

---

# S3-compatible

Works against Cloudflare R2, Backblaze B2, MinIO, Wasabi, DigitalOcean
Spaces, and AWS S3. One `PUT` per screenshot. Unlike Immich this has real
paths — the key prefix is a genuine folder — and needs no second call for a
link, since an object's URL is deterministic.

## Signing

`AWSSignatureV4` is hand-rolled on CryptoKit: no SDK, no dependency. Only
signed-header requests with a known payload hash are implemented (no chunked
streaming, no presigned URLs), which is all an object PUT/GET needs.

**This code is verified, and re-verifying it is cheap — do that rather than
eyeballing changes.** The method:

1. A from-spec Python reference is checked against AWS's **official**
   test-suite vectors, mirrored in botocore at
   `tests/unit/auth/aws4_testsuite/` (`.req` input, `.creq`/`.sts`/`.authz`
   expected). 12/12 checks must pass — that validates the reference.
2. The Swift signer is compiled standalone (`swiftc AWSSignatureV4.swift
   main.swift`) and its `Authorization` headers compared against that
   validated reference across S3-shaped cases: non-standard ports, explicit
   default ports, ACL headers, spaces/unicode/reserved characters in keys,
   empty payloads, and query strings needing sorting.

That process caught three real bugs that all compiled and looked correct:

- **`URL.path` drops a trailing slash.** A bucket-root request
  (`/bucket/?list-type=2`, i.e. the connection test) was signed as `/bucket`
  while the server signs `/bucket/` → `SignatureDoesNotMatch`. Fixed by
  reading `URLComponents.percentEncodedPath` instead, then decoding and
  re-encoding each segment.
- **The Host header must include a non-default port.** `URL.host` omits it,
  so anything on `:9000` (a self-hosted MinIO — a primary target) failed.
  `hostHeader(for:)` now mirrors what URLSession actually sends.
- **Content-Length must not be set manually.** URLSession reserves it and
  sets it from the body; signing our own value put it in `SignedHeaders`, so
  a rewrite or drop by URLSession would break the signature.

Two further details the spec is easy to get wrong, both handled:

- **URI encoding** is AWS's own rule — unreserved is `A-Za-z0-9-_.~`,
  everything else percent-encoded with **uppercase** hex. This is *not* what
  `addingPercentEncoding(withAllowedCharacters:)` does, so `uriEncode` is
  written by hand. (S3 encodes the path once; other AWS services encode
  twice.)
- **Canonical query strings** sort by encoded key, with encoded values.

## Configuration notes

- **Endpoint** is the service address *without* the bucket.
- **Path-style** (`endpoint/bucket/key`) is the default: required by MinIO,
  accepted by R2 and B2. Turn it off for AWS S3, which prefers
  virtual-hosted (`bucket.endpoint/key`).
- **Public base URL** is a CDN or custom domain. R2 in particular serves
  objects from a completely different domain than its API endpoint, so
  without this the copied link won't resolve.
- **"Make uploads publicly readable"** sends `x-amz-acl: public-read`. AWS
  and MinIO honour it; **Cloudflare R2 rejects ACLs entirely** and will fail
  the upload — leave it off there and make the bucket public in R2's own
  settings. That specific failure is translated in `S3Error`.
- **Object keys** replace spaces with `-`. Spaces are legal in S3 keys but
  produce links that break when pasted into chat clients, and the default
  timestamped filename is full of them.

S3's XML error codes are translated to plain language in `S3Error`, since
they're the difference between "your clock is wrong"
(`RequestTimeTooSkewed`), "your key is wrong" (`SignatureDoesNotMatch`), and
"your permissions are wrong" (`AccessDenied`) — otherwise all just a 403.

---

## App Transport Security

Self-hosted instances (both Immich and MinIO) are usually reached over plain
HTTP on a LAN, which ATS blocks by default.

`Config/Info.plist` sets `NSAppTransportSecurity` →
`NSAllowsLocalNetworking`, which permits cleartext to private-range IPs,
loopback, and `.local` names **only** — public hosts still require HTTPS,
unlike the blunt `NSAllowsArbitraryLoads`.

Two non-obvious details:

- The file lives in `Config/`, **outside** `QuickSnap/`, because that folder
  is a synchronized file group — anything inside it joins the target
  automatically, and an `Info.plist` there would also be copied in as a
  bundle resource.
- `GENERATE_INFOPLIST_FILE` stays `YES`. Xcode merges the `INFOPLIST_KEY_*`
  build settings (`LSUIElement`, category, copyright…) on top of the file, so
  only keys that can't be expressed as a flat build setting belong in it.
  `NSLocalNetworkUsageDescription` *can*, so it stayed a build setting.

## Known gaps

- **No retry or queue.** A failed upload is reported and dropped; the
  screenshot is still saved locally if that action is on.
- **No upload progress.** The toast is indeterminate. Real progress needs
  `URLSession`'s delegate-based upload task rather than the async
  `data(for:)` convenience.
- **Immich duplicates still get filed and linked** — a re-upload can mint a
  second shared link.
- **The markup toolbar's button keys off `uploadingEnabled` only**, not off
  credentials actually being valid, so a half-configured provider shows the
  button and fails at upload time with an explanatory toast.
- **S3 uploads are a single PUT**, so there's no multipart fallback. Not a
  practical limit for screenshots — the single-PUT cap is far above any
  capture.
- **Neither provider has been exercised against a live server** from this
  machine; the S3 signing is verified against AWS's official vectors, and
  Immich against its published OpenAPI spec.
