"use client";

import { useCallback, useEffect, useState } from "react";

import { supabaseBrowser } from "@/lib/supabase/client";

/**
 * Every admin screen is the same shape: call one `admin_*` RPC, render what comes back, call
 * another when a button is pressed, reload.
 *
 * The RPCs gate on `app.is_admin()` themselves, so this holds no permission logic — a non-admin
 * calling them gets a 42501 from Postgres, not a hidden button.
 */
export function useAdminData<T>(fn: string, args: Record<string, unknown> = {}) {
  const [data, setData] = useState<T | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const serialised = JSON.stringify(args);

  const load = useCallback(async () => {
    setLoading(true);
    const { data: result, error: rpcError } = await supabaseBrowser().rpc(
      fn,
      JSON.parse(serialised),
    );

    if (rpcError) {
      setError(rpcError.message);
      setData(null);
    } else {
      setError(null);
      setData(result as T);
    }

    setLoading(false);
  }, [fn, serialised]);

  useEffect(() => {
    void load();
  }, [load]);

  return { data, loading, error, reload: load };
}

export type ActionResult = { ok: boolean; error?: string };

export async function adminAction(
  fn: string,
  args: Record<string, unknown>,
): Promise<ActionResult> {
  const { data, error } = await supabaseBrowser().rpc(fn, args);

  if (error) return { ok: false, error: error.message };

  const result = data as ActionResult | null;
  return result ?? { ok: false, error: "no_result" };
}
