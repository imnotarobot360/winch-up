"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";

import { adminAction, useAdminData } from "@/components/admin/use-admin";
import { Button, Callout, Card, Field, TextArea, TextInput, Toggle } from "@/components/ui/primitives";

type Agreement = {
  id: string;
  version: number;
  is_current: boolean;
  effective_at: string | null;
  created_at: string;
  requires_resignature: boolean;
  body_hash: string;
  body_en: string;
  body_es: string;
  signature_count: number;
  hash_intact: boolean;
};

type Signature = {
  id: string;
  legal_name: string;
  email: string | null;
  version: number;
  body_hash: string;
  signed_at: string;
  signed_ip: string | null;
  signed_via: string;
};

/**
 * Requirement 12: publish versions, and read the signature records.
 *
 * The gate is NOT switchable from here. It is an app_setting and it is changed on the Settings
 * screen like every other one, which keeps one place where the behaviour of the app is turned
 * on and off. What this screen does is tell the admin which way it is currently set, because
 * publishing an agreement and expecting it to be enforced is the obvious mistake to make.
 *
 * Signature records are legal names, emails and IP addresses. Loading this list writes a row to
 * the audit log -- the RPC does it, not this component, so it cannot be avoided by calling the
 * RPC another way.
 */
export function AdminMembership() {
  const t = useTranslations("membership.admin");
  const { data, loading, error, reload } = useAdminData<{
    ok: boolean;
    required: boolean;
    agreements: Agreement[];
    total_signatures: number;
  }>("admin_membership_agreements");

  const [bodyEn, setBodyEn] = useState("");
  const [bodyEs, setBodyEs] = useState("");
  const [resign, setResign] = useState(true);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const [openVersion, setOpenVersion] = useState<number | null>(null);

  async function publish() {
    setBusy(true);
    setFailure(null);
    setNotice(null);

    const result = await adminAction("admin_publish_membership_agreement", {
      p_body_en: bodyEn,
      p_body_es: bodyEs,
      p_requires_resignature: resign,
      p_effective_at: null,
    });

    setBusy(false);

    if (!result.ok) {
      setFailure(result.error ?? "error");
      return;
    }

    setBodyEn("");
    setBodyEs("");
    setNotice(t("published", { version: (result as { version?: number }).version ?? "" }));
    void reload();
  }

  if (loading) return <p className="text-base text-ink-soft">…</p>;
  if (error) return <Callout tone="danger">{error}</Callout>;

  const agreements = data?.agreements ?? [];
  const broken = agreements.filter((a) => !a.hash_intact);

  return (
    <div className="space-y-5">
      <div>
        <h2 className="text-xl font-bold">{t("title")}</h2>
        <p className="text-base text-ink-soft">{t("subtitle")}</p>
      </div>

      {/* The single most important thing on this screen: whether any of it is in force. */}
      <Callout tone={data?.required ? "good" : "neutral"}>
        {data?.required ? t("gateOn") : t("gateOff")}
      </Callout>

      {/* Should be impossible -- the trigger refuses the edit that would cause it. Shown anyway,
          loudly, because a guarantee nobody checks is a guarantee nobody notices breaking. */}
      {broken.length > 0 ? (
        <Callout tone="danger">
          <p className="font-bold">{t("hashBroken")}</p>
          <p className="mt-1 text-sm">
            {broken.map((a) => `v${a.version}`).join(", ")}
          </p>
        </Callout>
      ) : null}

      <Card className="space-y-4 p-4">
        <h3 className="text-lg font-bold">{t("publish")}</h3>

        <Field label={t("bodyEn")}>
          <TextArea rows={8} value={bodyEn} onChange={(e) => setBodyEn(e.target.value)} />
        </Field>

        <Field label={t("bodyEs")}>
          <TextArea rows={8} value={bodyEs} onChange={(e) => setBodyEs(e.target.value)} />
        </Field>

        <Toggle
          checked={resign}
          onChange={setResign}
          label={t("requiresResignature")}
          hint={t("requiresResignatureHint")}
        />

        {failure ? <Callout tone="danger">{failure}</Callout> : null}
        {notice ? <Callout tone="good">{notice}</Callout> : null}

        <Button onClick={publish} disabled={busy || !bodyEn.trim() || !bodyEs.trim()}>
          {busy ? t("publishing") : t("publishCta")}
        </Button>
      </Card>

      <section className="space-y-3">
        <h3 className="text-lg font-bold">
          {t("versions")} · {t("signatureCount", { count: data?.total_signatures ?? 0 })}
        </h3>

        {agreements.map((a) => (
          <Card key={a.id} className="space-y-2 p-4">
            <div className="flex flex-wrap items-center gap-2">
              <span className="font-bold">v{a.version}</span>
              <span
                className={
                  a.is_current
                    ? "rounded-full bg-good-tint px-2 py-0.5 text-sm font-semibold text-good"
                    : "rounded-full bg-surface-sunk px-2 py-0.5 text-sm text-ink-faint"
                }
              >
                {a.is_current ? t("current") : t("retired")}
              </span>
              <span className="text-sm text-ink-faint">
                {t("signatureCount", { count: a.signature_count })}
              </span>
            </div>

            <p className="font-mono text-xs break-all text-ink-faint">{a.body_hash}</p>

            <Button
              variant="quiet"
              size="md"
              className="w-auto"
              onClick={() => setOpenVersion(openVersion === a.version ? null : a.version)}
            >
              {t("signatures")}
            </Button>

            {openVersion === a.version ? <SignatureList version={a.version} /> : null}
          </Card>
        ))}
      </section>
    </div>
  );
}

/**
 * Loaded only when an admin opens a version, not eagerly with the list.
 *
 * Two reasons, and the second is the real one: these rows are personal data, and the audit entry
 * should say an admin looked at them because they chose to, not because a page rendered.
 */
function SignatureList({ version }: { version: number }) {
  const t = useTranslations("membership.admin");
  const [search, setSearch] = useState("");
  const { data, loading } = useAdminData<{ ok: boolean; total: number; signatures: Signature[] }>(
    "admin_membership_signatures",
    { p_version: version, p_search: search || null, p_limit: 50, p_offset: 0 },
  );

  const rows = data?.signatures ?? [];

  return (
    <div className="space-y-3 border-t border-line pt-3">
      <p className="text-sm text-ink-faint">{t("viewingAudited")}</p>

      <Field label={t("searchLabel")}>
        <TextInput value={search} onChange={(e) => setSearch(e.target.value)} />
      </Field>

      {loading ? <p className="text-sm text-ink-soft">…</p> : null}

      {!loading && rows.length === 0 ? (
        <p className="text-sm text-ink-soft">{t("noSignatures")}</p>
      ) : null}

      {rows.map((s) => (
        <div key={s.id} className="rounded-field border border-line p-3 text-sm">
          <p className="font-semibold">{s.legal_name}</p>
          {s.email ? <p className="text-ink-soft">{s.email}</p> : null}
          <p className="text-ink-faint">
            {t("colSignedAt")}: {new Date(s.signed_at).toLocaleString()} · {t("colVersion")}{" "}
            {s.version} · {s.signed_via}
          </p>
          {s.signed_ip ? (
            <p className="text-ink-faint">
              {t("colIp")}: {s.signed_ip}
            </p>
          ) : null}
          <p className="font-mono text-xs break-all text-ink-faint">
            {t("colRef")}: {s.body_hash}
          </p>
        </div>
      ))}
    </div>
  );
}
