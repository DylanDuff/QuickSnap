# MCP server

QuickSnap can expose its capture surface to MCP clients, so an AI coding
agent can screenshot a window or read text off the screen itself instead of
waiting to be handed a file.

Off by default. Settings → Intelligence turns it on and prints the client
configuration to paste.

## Why HTTP and not stdio

MCP's usual local transport is stdio: the client launches the server as a
child process and talks over pipes. That does not fit here — QuickSnap is a
menu-bar app that is *already running*, and there is nothing for a client to
launch. The two workable shapes were:

1. **A helper executable in the bundle** that clients spawn, forwarding to the
   running app over XPC. Matches the usual pattern, opens no port, but adds a
   second binary, its own signing story, and an IPC protocol to design and
   version.
2. **An HTTP endpoint hosted by the app** — MCP's Streamable HTTP transport,
   which clients support directly.

We took (2). One process, no IPC, and the client config is four lines.

The cost is a listening socket, so the posture around it is deliberate:

- **Loopback only.** `NWParameters.requiredLocalEndpoint` is bound to
  `127.0.0.1`, not merely `NWListener(on:)` — a capture server reachable from
  the LAN would be a different product.
- **Off by default**, because it opens a socket that can screenshot the
  display.
- **Bearer token**, 32 random bytes generated on first use and kept in the
  **Keychain**, never UserDefaults — a defaults plist is readable by anything
  running as the user, and this token authorises screenshots. Requests
  without it get a 401 before anything else is looked at.
- **`Origin` validated.** The MCP spec requires this for local HTTP servers:
  without it, any web page the user visits could POST to `127.0.0.1` from
  their browser (DNS rebinding). A real MCP client sends no `Origin`, so
  absent is allowed and non-loopback origins are refused.
- **A toast on every agent-initiated capture.** Interactive selection shows an
  overlay, so the user already knows. Nothing else does, and a screenshot
  taken with no visible sign is not something to ship.

## Transport details

`HTTPMessage` implements only what the transport needs: a request with a
`Content-Length` body, one response, `Connection: close`. No keep-alive means
no partially-consumed stream to track, and clients reconnect per call anyway.
Chunked encoding is unsupported; bodies over 1 MB get a 413 rather than being
buffered.

Responses are always `application/json` — the server never needs to stream, so
it does not open an SSE channel. Sessions are not used (`Mcp-Session-Id` is
absent), which the spec permits for a stateless server.

`JSONValue` exists because tool arguments and results are dynamically shaped
and `[String: Any]` from `JSONSerialization` is not `Sendable`.

## Tools

| Tool | Interactive | Notes |
| --- | --- | --- |
| `capture_area` | **yes** | Shows the selection overlay and waits. 90 s timeout; cancelling returns a tool error, not a hang. |
| `capture_window` | no | Frontmost window whose app name contains `app`, optionally filtered by `title`. |
| `capture_screen` | no | Whole display, by index or the one under the pointer. |
| `read_screen_text` | no | Vision OCR, text only, no image — much cheaper when you only need to *read* something. |
| `list_windows` | no | What's on screen, frontmost first. |
| `list_recent_captures` | no | Saved captures, newest first. |
| `search_captures` | no | Ranked matches from the capture index — by text in the image, description, name, app or window. |
| `get_capture` | no | One saved capture by name. |

Two deliberate departures from the original issue:

- **`capture_window` never falls back to the hover overlay.** An agent can't
  see an overlay, so a blocking prompt is a worse failure than a deterministic
  choice: it takes the frontmost match, and when nothing matches it returns an
  error *listing what is open*, which is directly actionable.
- **`list_windows` was added.** It's the companion that stops an agent from
  having to guess-and-fail.
- **`search_captures` was added** once the capture index existed
  (`docs/search.md`). `list_recent_captures` only answers "the one just
  taken"; a user describing a screenshot from last week needs the index, and
  the agent gets the same ranking the search panel does. It returns names,
  paths and a snippet — **not images** — because handing a model ten
  screenshots to pick between is exactly the context blow-up the result shape
  below exists to avoid; `get_capture` is the follow-up.

### Result shape

Captures come back as a downscaled PNG inline (longest edge 1568 px) **plus a
text line with the full-resolution file path**. A retina full-screen capture
base64'd into JSON runs to tens of megabytes, which would eat a model's
context on one call; an agent that needs the detail reads the file instead.

Fresh captures are written to a temp file for that path. They are **not**
saved into the user's folder, and none of the after-capture actions run: an
agent asked for pixels, so saving a file, overwriting the clipboard and
popping a preview panel on every call would be noise nobody asked for.
Window captures also skip `WindowBackgroundRenderer` — a wallpaper-padded
presentation shot is worse input than the bare window.

Tool *failures* are returned as successful JSON-RPC responses carrying
`isError`, not as protocol errors. The distinction matters: a protocol error
is the client's problem, while these are results the model is meant to read
and act on, so every message is written to tell it what to do next ("No
on-screen window matches "Xcode". Currently open: …").

### What agents can't reach

`list_recent_captures`, `search_captures` and `get_capture` only ever see
files carrying QuickSnap's `FileTag` xattr — the same invariant that makes retention safe.
The save folder is user-chosen and the app is unsandboxed, so an unfiltered
listing would let a client enumerate and fetch files QuickSnap never wrote.
`get_capture` also rejects any name containing a path separator outright
rather than resolving it. `search_captures` inherits the same guarantee for
free: the index is only ever fed tagged captures, and it drops rows whose
file has disappeared. Its query text can't reach FTS5's own syntax either —
see `docs/search.md`.

## Verifying by hand

```bash
BASE=http://127.0.0.1:8787/mcp
AUTH="Authorization: Bearer <token from Settings → Intelligence>"

curl -s -X POST $BASE -H "$AUTH" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

curl -s -X POST $BASE -H "$AUTH" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call",
       "params":{"name":"list_windows","arguments":{}}}'
```

Verified this way when the server landed: 401 without a token, 403 for a
non-loopback `Origin`, 404 off-path, 405 on GET, 202 for a notification,
`initialize`/`tools/list` handshake, `-32601` for an unknown method, `-32700`
for a malformed body, `list_recent_captures` against real files, path
traversal refused, missing arguments refused, and the permission-denied
degradation.

### Two traps when testing from a terminal

- **`defaults read/write com.dylanduff.QuickSnap` does not read what the app
  reads.** A leftover sandbox container at
  `~/Library/Containers/com.dylanduff.QuickSnap/` makes the `defaults` CLI
  redirect there, while the unsandboxed app reads
  `~/Library/Preferences/com.dylanduff.QuickSnap.plist`. They drift silently.
  Address the plist by path, and quit the app first — a running instance
  holds the domain cached and flushes over external writes.
- **A terminal-launched instance has no Screen Recording permission.** TCC
  attributes the grant to the *responsible* process, which is the terminal, so
  every capture tool returns the permission error no matter what QuickSnap
  itself is allowed. The capture tools have to be exercised from a normally
  launched app.
