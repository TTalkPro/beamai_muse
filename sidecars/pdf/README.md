# sidecars/pdf

Port program used by `muse_pdf` (designs/04-integrations.md §2). It reads `{packet,4}`
frames (4-byte big-endian length + JSON) from stdin and writes replies the same way:

| request | reply |
|---|---|
| `{"op":"inspect","pdf":<base64>}` | `{"ok":{"pageCount":N,"fields":[{name,value,type}]}}` |
| `{"op":"fill","pdf":<base64>,"values":{name: string\|bool}}` | `{"ok":{"pdf":<base64>}}` |
| `{"op":"sample"}` | `{"ok":{"pdf":<base64>}}` |
| any failure | `{"error":"PdfError","message":...}` |

Behaviour is ported from OpenMuse `packages/integrations/src/pdf.ts` (spec §5.3–§5.5).
Implemented in M2-3; install with `npm ci` (or `make sidecars`).
