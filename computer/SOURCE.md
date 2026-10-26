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
`openbox-menu.xml`, the right-click menu (terminal, Writer, Calc; no web
browser, since the computer is offline).
