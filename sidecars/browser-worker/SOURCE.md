# sidecars/browser-worker

Copied verbatim from OpenMuse `apps/worker` at `1ac68f3` (Node + Playwright 1.62.1).
The HTTP contract is documented in designs/ref/openmuse-integrations-spec.md §7.1;
`muse_browser` is its only client. Do not change the source here — fixes go upstream
or into the Erlang client.

Runtime note: `npm start` uses `node --experimental-strip-types`, which needs Node 22.6+.
The remote host has Node 20, so `scripts/run-browser-worker.sh` (M2-5) runs it with `npx tsx`
instead. Chromium: `npx playwright install chromium`.
