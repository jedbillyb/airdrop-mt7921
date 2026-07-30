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
