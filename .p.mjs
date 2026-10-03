import { readFileSync, writeFileSync } from "node:fs";
const p = "docs/probe-2026-10-03.sh";
let s = readFileSync(p, "utf8");

const old = `    42703) printf '  MISSING      %-32s (42703 -- no such column)\n' "$t.$c" ;;`;
const neu = `    42703) printf '  MISSING      %-32s (42703 -- no such column)\n' "$t.$c" ;;
    # A column on a table that does not exist AT ALL answers PGRST205 ("could not find the table
    # in the schema cache") rather than 42703: PostgREST resolves the relation before the column,
    # so a missing table short-circuits the column check. Measured on 2026-10-03 against a
    # production that had none of the new tables yet. Three codes, not two.
    PGRST205) printf '  MISSING      %-32s (PGRST205 -- no such table)\n' "$t.$c" ;;`;
if (!s.includes(old)) throw new Error("anchor missing");
s = s.replace(old, () => neu);

const oldHdr = `#                42501  -> the column is there, the table is gated. APPLIED.`;
const newHdr = `#                42501  -> the column is there, the table is gated. APPLIED.
#                PGRST205 -> the TABLE does not exist, so the column was never reached.
#                           NOT APPLIED. PostgREST resolves the relation before the column name,
#                           so a brand-new table answers this instead of 42703.`;
s = s.replace(oldHdr, () => newHdr);
writeFileSync(p, s);
console.log("ok");
