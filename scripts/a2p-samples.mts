/**
 * Sample messages for A2P 10DLC campaign registration.
 *
 *   npm run a2p:samples
 *
 * Carriers compare the samples on the campaign against what actually goes out, and a campaign
 * whose samples do not match real traffic gets rejected — sometimes months later, after it has
 * been approved and is carrying real call-outs. So these are RENDERED from the same templates the
 * app sends rather than written out by hand, and regenerated whenever the copy changes.
 *
 * Only templates in `sms.enabled_templates` are included. Registering samples for messages the
 * app does not send is the same mismatch in the other direction.
 */
import { renderSms } from "../src/lib/sms/templates";

/**
 * Realistic values, not placeholders. A sample with `{short_code}` still in it is rejected, and
 * so is one that reads as obviously synthetic.
 */
const CASES: { key: string; note: string; params: Record<string, unknown> }[] = [
  {
    key: "responder.offer",
    note: "The call-out. Sent to volunteers near a recovery request, after they signed up and confirmed their number.",
    params: {
      short_code: "TX-4F21",
      vehicle_class: "truck",
      miles: 12,
      stuck_type: "mud",
      stuck_depth: "frame",
      needs_tractor: false,
      needs_second_truck: true,
      county: "Montgomery",
    },
  },
  {
    key: "responder.already_covered",
    note: "Sent to volunteers who answered a call-out that somebody else took first.",
    params: { short_code: "TX-4F21" },
  },
  {
    key: "responder.help",
    note: "The HELP reply. Required by carriers.",
    params: {},
  },
];

for (const { key, note, params } of CASES) {
  for (const locale of ["en", "es"] as const) {
    const body = renderSms(key, params, locale);
    if (!body) {
      console.error(`  ${key} (${locale}) rendered nothing — the template key may have changed`);
      continue;
    }
    console.log(`\n--- ${key} · ${locale} · ${body.length} chars ---`);
    console.log(note);
    console.log("");
    console.log(body);
  }
}

console.log(`
------------------------------------------------------------------
Every sample above ends with STOP instructions, which carriers require on any
message that asks somebody to do something. If one does not, fix the template
rather than the sample -- the sample is supposed to be what we really send.
`);
