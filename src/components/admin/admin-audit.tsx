"use client";

import { useFormatter, useTranslations } from "next-intl";

import { Callout, Card } from "@/components/ui/primitives";

import { useAdminData } from "./use-admin";

type AuditRow = {
  id: number;
  action: string;
  entity: string | null;
  entity_id: string | null;
  data: Record<string, unknown>;
  created_at: string;
  actor: string | null;
};

/**
 * Admins can see every phone number in the system, so what they do is written down.
 * Read-only by design: there is no RPC that edits or deletes an audit row.
 */
export function AdminAudit() {
  const t = useTranslations("admin.audit");
  const format = useFormatter();

  const { data, loading, error } = useAdminData<AuditRow[]>("admin_audit_log", { p_limit: 200 });

  if (loading) return <p className="text-center text-ink-faint">{t("loading")}</p>;
  if (error) return <Callout tone="danger">{error}</Callout>;

  if ((data ?? []).length === 0) {
    return (
      <Card>
        <p className="text-center text-lg text-ink-soft">{t("empty")}</p>
      </Card>
    );
  }

  return (
    <ul className="space-y-2">
      {(data ?? []).map((row) => (
        <li key={row.id} className="rounded-field border border-line p-3">
          <p className="font-mono text-sm font-semibold">{row.action}</p>
          <p className="text-sm text-ink-soft">
            {row.actor ?? t("unknownActor")} ·{" "}
            {format.dateTime(new Date(row.created_at), {
              dateStyle: "short",
              timeStyle: "short",
            })}
          </p>
          {row.entity ? (
            <p className="text-sm text-ink-faint">
              {row.entity} {row.entity_id}
            </p>
          ) : null}
          {Object.keys(row.data ?? {}).length > 0 ? (
            <pre className="mt-1 overflow-x-auto text-xs text-ink-faint">
              {JSON.stringify(row.data)}
            </pre>
          ) : null}
        </li>
      ))}
    </ul>
  );
}
