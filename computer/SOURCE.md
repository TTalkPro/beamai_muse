# computer/

Copied verbatim from OpenMuse `apps/computer` at `1ac68f3` (`Dockerfile`, `files.py`).
Keep these files byte-identical to upstream; the Erlang side (`muse_computer_docker`)
depends on the files.py stdin/stdout JSON protocol (designs/ref/openmuse-integrations-spec.md §6.6).

Build the image: `make computer-image` (tag `openmuse-computer:local`).

`Dockerfile.desktop` and `desktop-init` are not from OpenMuse: they build the
desktop variant (COMPUTER_DESKTOP=true; Xvfb + openbox + xterm, LibreOffice,
mupdf), tag `openmuse-computer-desktop:local`, with `make computer-desktop-image`.
`muse_computer_docker` checks its entrypoint `/opt/openmuse/desktop-init`.
`Xresources` (xterm on Xft fonts, appended to its app-defaults) and `gui` (start a GUI
program detached, `/usr/local/bin/gui`) belong to that variant too, as does
`openbox-menu.xml`, the right-click menu (terminal, Writer, Calc). The
desktop image also carries the browser of `browser/` (named build context
`browser`; muse starts it on the first browser request of the computer's
conversation or task, see docs/browser.md).

Not from OpenMuse: both images add `ca-certificates` and `curl`, so with
`COMPUTER_NETWORK=bridge` git, pip and curl can use HTTPS.

`files.py` adds two operations to OpenMuse's: `read_file` and `write_file`, any
regular file up to 10 MB as base64 (the computer page's download and upload),
and `changed_since` (M9-11): the regular files under /workspace changed since a
time, for the chat's reply products (designs/04-integrations.md §3.1). Its walk
is unit-tested on a temporary directory by `tests/test_files.py` (not copied
into the images). The script now runs `main()` only as `__main__`, so the test
can import it.
