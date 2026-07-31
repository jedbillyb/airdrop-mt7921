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
