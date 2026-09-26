# OpenDrop patches for iOS 26

These patch OpenDrop 0.13.0 in place, inside whatever virtualenv you installed
it into. That means they do not survive rebuilding the venv, so they live here
and get reapplied:

```sh
cd .venv-opendrop/lib/python3.14/site-packages
git apply /path/to/airdrop-mt7921/patches/opendrop-ios26-airdrop.patch
```

(Void has no `patch(1)` installed; `git apply` works and the patch is verified
against it.)

**They are a series, not a menu.** Each patch is made against OpenDrop 0.13.0
with every earlier patch already applied, so they only apply in this order:

```
ios26-airdrop recv-window py314-send mdns-repeat find-report tls-keylog
upload-arms ask-confirm mdns-reannounce threaded-server url-items
zeroconf-update-service salvage-truncated salvage-trim send-multifile
send-status
```

The install loop in the [main README](../README.md) uses exactly that order.
Verified 2026-09-15: all thirteen apply with plain `git apply` to a clean
`opendrop==0.13.0` from PyPI, and the result compiles. Before 2026-09-14
`recv-window` and `threaded-server` only applied with reduced context, and
`mdns-reannounce` did not apply at all (one hunk had turned a blank context
line into an added one). A new patch must be generated against the tip of
this series and added to the end of both lists.

## opendrop-threaded-server.patch

Makes `HTTPServerV6` subclass `ThreadingHTTPServer` (with `daemon_threads`)
instead of the stock single-threaded `HTTPServer`.

iOS sends `Connection: keep-alive` and then holds the connection open idle. A
single-threaded server stays parked in `handle_one_request()` on that idle
socket and never gets back to `accept()`, so the next connection - the one
carrying the file - sits unread in the kernel queue indefinitely. The phone
shows this as "Waiting...". Observed directly: an ESTABLISHED socket on 8771
with **Recv-Q 1496** while opendrop had logged nothing for twelve minutes.

This is the same single-thread bottleneck that made a slow consent prompt fill
the listen backlog with iOS's validation connects and get us dropped from the
share sheet, which `airdropd` worked around by cutting the prompt timeout to
15s. Threading removes the class of stall rather than tuning around it.

## opendrop-mdns-reannounce.patch

Re-sends the receiver's mDNS announcement every
`OPENDROP_ANNOUNCE_INTERVAL` seconds (default 5) from a daemon thread, without
touching the registration or the HTTPS listener.

python-zeroconf announces at registration and then goes quiet, and the iPhone
does not poll for AirDrop receivers - it only ever learns we exist by catching
an announce burst. Over AWDL that burst also has to survive a link we are only
co-channel on for a fraction of each 1.048 s sequence, so a single burst at
startup is routinely missed outright.

`airdropd` used to get the same effect by killing opendrop every 30 s and
letting it re-register. That deregistered the service and dropped the listener
for ~1.5 s per cycle, so the receiver visibly appeared and vanished on the
phone's share sheet on a 30 s period, and a transfer starting near the boundary
lost its socket. The kill loop is gone; `airdropd` now just passes the interval
through.

Note this is the receiving side. `opendrop-mdns-repeat.patch` is the sending
side - it repeats the PTR *query* while browsing, for the same reason.

## opendrop-ios26-airdrop.patch

Three fixes, all needed before an iPhone on iOS 26 can complete a transfer.
Each was found by hitting it in a live run on 2026-07-31 - see ../docs/FINDINGS.md §15.

1. **Chunked request bodies.** `handle_discover` and `handle_ask` read
   `int(self.headers["Content-Length"])`. iOS 26 sends both chunked with no
   Content-Length, so this raised `TypeError: int() argument must be ... not
   'NoneType'` and killed the connection before any reply was written. Adds
   `_read_request_body()`, handling both framings. `handle_upload` already
   coped with chunked; only these two paths did not.

2. **`application/x-dvzip`.** `handle_upload` accepted only
   `application/x-cpio` and answered 406 to anything else - after the user had
   already tapped send, which is what the phone reports as "Failed". iOS 26
   sends photos as dvzip. Both types are now accepted.

3. **dvzip container + buffer to disk.** libarchive does not recognise dvzip
   ("Unrecognized archive format"). The format is a run of length-prefixed
   blocks: a 4-byte big-endian header where bit 31 means the payload is STORED
   and the low 31 bits are its length; otherwise the payload is a zlib stream.
   Blocks decompress to 128 KiB each except the last. `dvzip_to_cpio()` decodes
   it into the ODC cpio inside. The body is also buffered to disk before
   extraction, so an unparseable container leaves the raw bytes on disk rather
   than a half-read socket and nothing to show for it.

Verified end to end: a 2.06 MB transfer decoded to 17 blocks consuming the file
exactly, yielding `IMG_8276.JPG`, a 4032x3024 JPEG.

## opendrop-url-items.patch

Delivers an AirDropped **link**. Adds `ask_items()` and `open_url()` to
`server.py`, names the URL in the consent prompt, and opens it after the user
accepts.

Sharing a link is not a file transfer. iOS puts the URL in the `/Ask` body's
`Items` array, leaves `Files` empty and **never sends an `/Upload`** - it treats
our 200 on `/Ask` as the whole transfer. Stock OpenDrop only ever looks at
`Files`, so a shared link produced a successful-looking share on the phone, an
"accept 0 files" prompt here, and nothing on disk. `/Ask` is therefore the only
place a URL can be delivered from, which is why this hooks the handler rather
than the receive directory.

The URL goes to `AIRDROP_URL_HOOK` (`daemon/airdrop-url`, which opens Firefox),
or `xdg-open` if that is unset. Two deliberate choices:

- **Only after consent.** The open call sits below the `_ask_user` check, so a
  declined share opens nothing.
- **Detached, never blocking.** The `/Ask` response is what tells the phone the
  share worked; waiting on a browser start would stall it into a timeout. The
  hook is `Popen`'d in a new session and its result is not waited for.

Scheme filtering happens twice on purpose - `http(s)` only in `ask_items()`, and
again in `airdrop-url`. The caller is an unauthenticated network peer, and the
hook is reachable on its own, so neither layer gets to assume the other ran.

## opendrop-recv-window.patch

Two correctness fixes around the receive path. **Neither improves throughput** -
that was measured and is written up in [../docs/FINDINGS.md](../docs/FINDINGS.md)
§18. They are here because the behaviour they fix is wrong on its own terms and
because they remove a confound from any future measurement.

Apply after `opendrop-ios26-airdrop.patch`.

1. **`SO_RCVBUF` on the listening socket.** Measured on a real transfer, the
   advertised receive window opened at 64766 B, collapsed to **528 B** - below one
   MSS - in a single step, and then took ~40 s to crawl back, which is longer than
   the transfer. AWDL delivers in ~68 ms bursts separated by ~450 ms of silence, so
   a connection gets only a couple of round trips per second and the kernel's
   receive-window recovery is correspondingly glacial. A large fixed buffer means
   the sender's opening burst cannot overrun us, so `rcv_ssthresh` never collapses.
   With this, the median window went 2 728 B -> 41 462 B.

2. **Answer `Expect: 100-continue` only when ready to read.** Upstream answered it
   before the chunked-encoding check, before building the reader and before opening
   the output file - so the sender began transmitting while the server was still
   getting ready. That race is what overran the buffer in the first place.

## opendrop-py314-send.patch

Three unrelated breakages that all sit on the **send** path, none of them
AirDrop-specific: OpenDrop 0.13.0 predates Python 3.12, Pillow 10 and current
`libarchive-c`, and each dependency removed something it relies on. Together they
meant `opendrop send` and `opendrop find` could not put a single packet on the
wire. Found by exercising the send path offline; the network half is still
untested.

1. **`HTTPSConnection` no longer takes `key_file`, `cert_file` or
   `check_hostname`** (deprecated in 3.6, removed in 3.12). `HTTPSConnectionAWDL`
   forwarded all three, so every send *and* every `find` died at construction with
   `TypeError: HTTPSConnection.__init__() got an unexpected keyword argument
   'key_file'`. They belong on the `SSLContext` now, which
   `AirDropConfig.get_ssl_context()` already builds via `load_cert_chain()` - so
   in normal use there is nothing to carry over.

2. **`libarchive-c` changed `ArchiveEntry.__init__`.** The second positional
   argument is now `header_codec` (a str) and the entry allocates its own C
   struct. `AbsArchiveWrite.add_abs_file()` called `ArchiveEntry(None, entry_p)`,
   putting a pointer where the codec goes, and died on the first pathname
   assignment with `TypeError: encode() argument 'encoding' must be str, not int`.
   The rewrite lets `ArchiveEntry` own its struct; note it drops the surrounding
   `new_archive_entry()` context manager on purpose, since that would free the
   same struct `ArchiveEntry.__del__` frees.

3. **`Image.ANTIALIAS` was removed in Pillow 10** (this box has 12.3.0). Sending
   any image calls `generate_file_icon()`, which used it.
   `Image.Resampling.LANCZOS` is the identical filter under its current name.

Verified offline: the cpio archive builds and round-trips (`070707` ODC magic),
the icon renders to JPEG2000, and `send_ask()` now runs all the way to the
network call instead of failing at import-time API mismatches.

## opendrop-mdns-repeat.patch

**The fix that first got the iPhone to answer us at all.** See
[../docs/FINDINGS.md](../docs/FINDINGS.md) §19.

`ServiceBrowser` backs its queries off 1s, 2s, 4s, 8s, ... which assumes a link
where a lost query is unusual. AWDL over a single radio is not that link: we are
only on the peer's channel for a fraction of each 1.048 s sequence, an mDNS query
is one unacknowledged multicast frame, and the answer has to survive the same
gauntlet coming back. Measured over a 75 s browse, the backoff produced **7
queries** - at t=0,1,3,7,15,31,63 - and by 30 s in it was asking once a minute.
None was answered.

`AirDropBrowser` now also runs a daemon thread that re-asks the `_airdrop._tcp`
PTR question at a steady interval, default 1.5 s, overridable with
`OPENDROP_QUERY_INTERVAL` (set it to 0 to disable). On the next run mDNS packets
in the browse window went 7 -> 68 and replies from the peer went **0 -> 14**.

Apply after `opendrop-py314-send.patch`.

## opendrop-find-report.patch

`opendrop find` could discover a receiver, print `Found index 0 ID ... name
...`, and still leave `~/.opendrop/discover.last.json` untouched - so the
`opendrop send` that followed read a hours-old report and died with **"Receiver
does not exist"** while the phone was sitting there discovered. Hit on
2026-07-31 on the send path; see [../docs/FINDINGS.md](../docs/FINDINGS.md) §27.

The report is the only channel through which `send` learns the receiver's
address and port. `Found ...` on stdout is not enough, and neither is passing
`-r <ID>`: `_get_receiver_info()` looks the ID up *inside the report*.

1. **Write the report before `browser.stop()`, not after.** `stop()` ends in
   `zeroconf.close()`, which this project has already measured hanging for over
   two minutes on an AWDL link. Ordered after it, the write simply never
   happened. Nothing about serialising `self.discover` needs the browser
   stopped; the callback thread is handled by taking `self.lock`.

2. **Write on every discovery, not only at shutdown.** A browse driven by a
   script gets killed once it has printed what the caller wanted, and that is a
   legitimate way to use it.

3. **Write atomically** (temp file in the same directory, `fsync`, `rename`), so
   a reader never sees a half-written report and an interrupted write cannot
   destroy the previous one.

Apply after `opendrop-mdns-repeat.patch`.

## opendrop-tls-keylog.patch

A diagnostic, not a fix, and inert unless `SSLKEYLOGFILE` is set.

Every AirDrop failure after the TLS handshake looks the same from outside:
`http.client.RemoteDisconnected: Remote end closed connection without response`.
That one message covers "the phone rejected our headers", "the phone gave up
waiting for the body", and "the link dropped mid-upload", and they need
different fixes. CPython wires `SSLKEYLOGFILE` up only inside
`ssl.create_default_context()`; `AirDropConfig.get_ssl_context()` builds its
context by hand, so the variable was being ignored. Setting
`ctx.keylog_filename` makes a capture of the send decryptable:

```sh
tshark -r send.pcap -o tls.keylog_file:sslkeys.log -Y http
```

`airdrop.sh send` now captures `send.pcap` and sets `SSLKEYLOGFILE` for the run.

## opendrop-upload-arms.patch

**This is what makes sending work.** It began as an experiment and ended as the
fix; the history is kept because the dead ends are informative. Result first,
then how we got there.

### SOLVED (§37): announce the TransferID in `/Ask`

The `/Upload` was refused because our `/Ask` never declared a `TransferID`, yet
`/Upload` asserted a fresh one - so the receiver had no accepted transfer to bind
it to and rejected on the headers. A real iOS 26 sender's `/Ask` body carries
`TransferID={'id': UUID}` and `TransferType`, and repeats the same id on
`/Upload`. `send_ask()` now does the same, and the default arm list collapses to a
single arm, `reuse-chunked-dvzip-rawhdr`, which is a byte-level copy of an
observed Apple upload: reused connection, chunked, dvzip container, Apple's exact
header set and order, no `Host`, no `Accept-Encoding`. On the wire:
`POST /Ask -> 200`, `POST /Upload -> 200 OK`, file delivered. **`SenderRecordData`
- the Apple-signed validation record - is not required.** Identity fields are
carried but not verified at `/Upload`; the receiver only enforces that the upload's
id was announced in an `/Ask` it accepted.

`send_ask()` also stashes the receiver's `/Ask` reply (`IDSSessionID`,
`ReceiverPseudonym`, `ReceiverPushToken`) on the client in case a future step
needs to echo it - see [../docs/FINDINGS.md §37](../docs/FINDINGS.md).

### How we got there (the arms)

See [../docs/FINDINGS.md](../docs/FINDINGS.md) §29-§37.

An iPhone on iOS 26 accepts `/Ask`, returns a full 200 with its receiver plist,
then took a complete and well-formed `/Upload` and answered with a TLS
**close_notify** instead of an HTTP status. Not transport loss: captured at 0%
ping loss with every byte ACKed. A server that dislikes a media type answers
406, so a silent close pointed elsewhere. The arms machinery below walked
candidate framings/containers/headers inside one accepted session. It ruled out a
lot - and every one of those arms shared the missing-TransferID defect, so their
"eliminations" only proved the receiver rejects an unannounced transfer. The real
answer came from diffing our request against a real Apple `/Ask` our own receiver
had saved to disk, not from the arms themselves.

`send_upload()` walks a list of arms inside one accepted session, controlled by
`OPENDROP_UPLOAD_ARMS`, because each candidate otherwise costs the user an
Accept tap. Read the result asymmetrically: **a success is conclusive, a failure
of a later arm is not**, since the phone may abandon the session after the first
rejection. Arm 1 reproduces upstream exactly and is the control.

Arm names are parsed by substring: `new` = fresh connection (default reuse),
`length` = `Content-Length` (default chunked), `dvzip` = Apple's container,
`plain` = bare cpio, `expect` = send `Expect: 100-continue`.

### Round one (all four failed)

`reuse-chunked-gzip`, `new-chunked-gzip`, `new-length-gzip`, `new-length-plain`.

Design flaw, recorded because it cost a run: arms 2-4 changed the connection
**and** the framing together, so none of them was attributable. Only arm 1 was
interpretable. The capture does show the phone accepting all three fresh TCP
connections, so it was not refusing to talk.

### Round two (also uninterpretable past arm 1)

Same failure of design, found in the capture rather than assumed: arms 2-4 went
out on **new TCP streams**. A refused `/Upload` kills the connection, so
`send_POST()` found `http_conn` at `None` and opened a fresh one - "reuse"
silently became "new", and worse, that connection carried no `/Ask`, so the
phone was asked to accept an upload for a session it had never agreed to on
that socket. Only arm 1 was ever a real test, in both rounds.

### Rounds three and four (eliminated container, framing and Expect)

Later rounds held the connection constant and copied what the phone demonstrably
does when it sends to us, varying one thing at a time: dvzip vs cpio+gzip vs bare
cpio; `Content-Length` vs chunked; `Expect: 100-continue` present vs absent; and
finally Apple's exact minimal header set (`rawhdr`). All refused, one of them 70 us
after our headers - too fast for the body to have been read, which said the request
was refused on its **headers**. That was the clue that sent us to compare headers,
and ultimately the whole `/Ask`, against a real Apple transfer - where the missing
`TransferID` announcement finally showed up (§37).

**Every arm after the first re-sends `/Ask`, so it prompts on the phone and costs
an Accept tap.** With the fix in place the default is a single arm, so a normal
send costs exactly one tap; the multi-arm machinery survives for future
experiments via `OPENDROP_UPLOAD_ARMS`.

The observed differences the arms copied are real: our receiver had to be taught
to answer `Expect: 100-continue` because the iPhone sends it, and to decode
`application/x-dvzip` because the iPhone sends that too.

`_cpio_to_dvzip()` is the exact inverse of `dvzip_to_cpio()` in `server.py`, and
round-trips through it for single- and multi-block payloads in both STORED and
zlib forms.

**Known limitation:** `http.client` does not implement `Expect: 100-continue`
properly - it sends the header and then the body without waiting for the 100.
The header is present on the wire, which is what the arm tests, but if the phone
requires a real wait this arm understates the case.


## opendrop-zeroconf-update-service.patch

`AirDropBrowser` defines `add_service` and `remove_service` but not
`update_service`, which python-zeroconf has required on a listener since 0.3x.
The call raises `AttributeError` **inside the ServiceBrowser thread**, which
kills it. Nothing surfaces from outside: the process stays up, the listener
object is still there, and discovery simply never reports anything again.

The failure is worse than a missing stub usually is, because a device that
re-announces itself fires `update` rather than `add` - and re-announcing is
exactly what the peer you are waiting for does. So the one event that matters
is the one that takes the thread down.

Reports an update the same way as an add.


## opendrop-salvage-truncated.patch

An interrupted transfer was discarded whole. Over 17 interrupted transfers on
one MT7922, **9 already contained the complete file** and had lost only the
container's terminator: the extracted JPEG matched the sender's sha256 exactly.

A later evening, on the same radio and link but with this patch in place, gave
12 of 12 verified-valid files and then 8 of 9 — a separate cohort, counted
differently (delivered files rather than recoverable ones), so the two figures
are not comparable and are kept apart deliberately.

The patch keeps those bytes and **verifies** what it returns. The check walks
the ODC cpio structure by hand, because libarchive **zero-pads** a truncated
member out to its declared size - a file can be exactly the right length and
end in 949,265 null bytes, so comparing sizes detects nothing at all. Anything
incomplete is suffixed `.partial`; quietly handing back a half-empty photo that
still opens would be worse than a clean failure. Both archive types get the
check: iOS 26 `x-dvzip`, and gzip'd `x-cpio`, which is decompressed without
requiring the gzip end-of-stream marker, since a cut-off transfer never has one.

**The read timeout follows the link's rhythm rather than being a constant.** A
flat 30 s was added to every salvaged transfer - thirty seconds of nothing out
of forty-three, measured. Shortening it blindly would cut off a merely slow
transfer, so the first attempt keyed a short tier off nearness to `TotalBytes`.
That assumes the sender stops at the edge, which is false: measured stops range
from 440 bytes to 943,642 bytes short, 0.03% to 24%. No threshold covers both.
(Both ends are from the same night; an earlier draft quoted the 4.9% case as
the maximum, before the transfer that stopped 24% short.)

So it no longer guesses where the end is. It watches the gap between successful
reads and arms the timeout at six times the worst gap seen, clamped to 8-30 s
(`AIRDROP_STALL_FLOOR`, `AIRDROP_STALL_TIMEOUT`). A steady link drops to the
floor within seconds; a choppy one lets the timeout climb on its own, and the
ceiling is the old value, so it can never wait *longer* than before. Verified
live: a worst gap of 3.2 s gave 19 s instead of 30 on a 6 MB photo that arrived
complete - and a fixed 8 s tier would have cut that one off.

The timeout sits on the **handler class** rather than on `/Upload` alone. `_next_chunk` blocked in `readline()` with no deadline, so a
phone that went quiet froze the loop forever and even the bytes already
received stayed in the buffer. The class-level placement is what matters:
`handle_ask` reads its request body *before* calling the consent hook, so a
peer stalling there hung with no prompt on screen and nothing in the log.

Applied last, since it touches `server.py` after every other patch has.

## opendrop-salvage-trim.patch

`salvage-truncated` marks an incomplete member `.partial` but keeps the file
libarchive wrote, and libarchive pads a truncated member out to its declared
size. The guarantee therefore held in name only: measured on two interrupted
transfers, a 1,781,751-byte photo carried 524,288 bytes of image and 1,257,463
bytes of nulls behind it, and a second carried 2,229,412 of 3,404,207. Nothing
in the file says where the picture stops, so every reader walks into padding.

The archive already knows. A truncated member is exactly the one whose
`data_off + filesize` runs past the end of what was received, so the bytes that
did arrive are `n - data_off`. `odc_members` now returns that count and
`verify_extracted` truncates to it before renaming.

Cutting at that offset rather than stripping trailing zeros matters: a file may
legitimately end in nulls, and a heuristic would eat them.

Verified against both transfers above - the computed offset matched the
hand-measured end of the image to the byte, and ffmpeg decodes the trimmed
files with only the `overread` a truncated JPEG is expected to give.

## opendrop-send-multifile.patch

`-f,--file` took exactly one path, so sending five files meant five transfers
and **five separate Accepts on the phone**. The protocol never required that:
`send_ask` already builds one entry per file and the receiver accepts the set in
a single `/Ask`, so the limitation was in the command line and in a caller that
had to loop around it.

`-f` becomes repeatable (`action="append"`), and `send_upload` iterates the list
it is given instead of wrapping a single path in a one-element list. A single
`-f` still yields a one-element list, so every existing caller behaves exactly
as before.

`-u,--url` rejects more than one `-f`: a URL send carries one item by
construction, and silently dropping the rest would be worse than refusing.
Each path is checked for existence before anything is brought up, so a typo in
the fifth file fails immediately rather than after four transfers.

Verified by reverse-applying against a venv carrying the thirteen patches ahead
of it. The daemon side of this lives in `daemon/airdropd`, whose `send_one` now
passes every file in one invocation.

## opendrop-send-status.patch

`opendrop send` exited 0 whatever happened. Every failure path in `send()`
was a bare `return`, `AirDropCli.__init__` did the work and `main()` returned
nothing, so a declined transfer, a receiver that was never found and a
completed upload were indistinguishable to any caller reading `$?`.

That is not a cosmetic difference here. `airdropd` reports send results from
this status, and reported days of transfers as successful that never left the
machine; anything else driving the CLI - a wrapper, a notification, a
progress indicator - was told the same thing.

`send()` now returns 1 on each failure path and 0 after "Uploading has been
successful", `__init__` keeps it on `self.status`, and `main()` returns that.
Nothing reads the value internally, so the only behaviour change is the exit
code the console script propagates.

Last in the series: it is the only patch touching `cli.py`, and generating it
against the tip keeps that true.
