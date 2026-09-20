// TxRecover :: dispatch tick
//
// Scheduled by pg_cron every 60 seconds (see the README). It holds no dispatch logic of its own:
// it calls the Postgres function that owns every transition, then pokes the app to drain the SMS
// outbox that the transitions filled.
//
// Deploy:  supabase functions deploy dispatch-tick --no-verify-jwt
// Secrets: supabase secrets set DISPATCH_TICK_SECRET=... SITE_URL=https://...

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TICK_SECRET = Deno.env.get("DISPATCH_TICK_SECRET");
const SITE_URL = Deno.env.get("SITE_URL");

Deno.serve(async (request: Request) => {
  if (!TICK_SECRET) {
    return Response.json({ error: "not_configured" }, { status: 503 });
  }

  // The cron job is the only thing allowed to advance the state machine.
  if (request.headers.get("authorization") !== `Bearer ${TICK_SECRET}`) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  const { data, error } = await supabase.rpc("advance_dispatch", { p_limit: 50 });

  if (error) {
    console.error("advance_dispatch failed", error);
    return Response.json({ error: error.message }, { status: 500 });
  }

  // The app owns the SMS templates, so it owns sending. If this call fails the messages stay
  // queued and the next tick picks them up — nothing is lost, it is just a minute later.
  let drained: unknown = null;

  if (SITE_URL) {
    try {
      const response = await fetch(`${SITE_URL.replace(/\/$/, "")}/api/sms/drain`, {
        method: "POST",
        headers: { authorization: `Bearer ${TICK_SECRET}` },
        signal: AbortSignal.timeout(20_000),
      });
      drained = await response.json().catch(() => null);
    } catch (drainError) {
      console.error("outbox drain failed", drainError);
    }
  }

  return Response.json({ dispatch: data, drained });
});
