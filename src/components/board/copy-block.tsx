"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";

import { Button } from "@/components/ui/primitives";

/**
 * The post text plus a Copy button.
 *
 * There is no "share to Facebook" here and there never will be: the Groups API was shut down, so
 * anything that claimed to post automatically would be lying.
 */
export function CopyBlock({ text }: { text: string }) {
  const t = useTranslations("post");
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 3000);
    } catch {
      setCopied(false);
    }
  }

  return (
    <div className="space-y-3">
      <pre className="overflow-x-auto whitespace-pre-wrap rounded-field border-2 border-line bg-surface-sunk p-4 font-mono text-sm leading-relaxed">
        {text}
      </pre>
      <Button type="button" onClick={copy}>
        {copied ? t("copied") : t("copy")}
      </Button>
    </div>
  );
}
