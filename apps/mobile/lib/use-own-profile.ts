import { useCallback, useEffect, useRef, useState } from "react";
import { AppState } from "react-native";

import { supabase } from "./supabase";

type ResponderProfile = {
  first_name?: string | null;
  recoveries_count?: number | null;
} | null;

const SITE_URL = process.env.EXPO_PUBLIC_SITE_URL?.replace(/\/+$/, "");

export function useOwnProfile() {
  const [signedIn, setSignedIn] = useState(false);
  const [firstName, setFirstName] = useState("Member");
  const [recoveriesCount, setRecoveriesCount] = useState(0);
  const [avatarUrl, setAvatarUrl] = useState<string | null>(null);
  const requestId = useRef(0);
  const avatarRetries = useRef(0);

  const signOwnAvatar = useCallback(async (accessToken: string) => {
    if (!SITE_URL) {
      setAvatarUrl(null);
      return;
    }

    try {
      const response = await fetch(`${SITE_URL}/api/photos/avatar/sign-read`, {
        method: "POST",
        headers: { Authorization: `Bearer ${accessToken}` },
      });
      if (!response.ok) {
        setAvatarUrl(null);
        return;
      }

      const result = (await response.json()) as { avatarUrl?: unknown };
      setAvatarUrl(typeof result.avatarUrl === "string" ? result.avatarUrl : null);
    } catch {
      setAvatarUrl(null);
    }
  }, []);

  const refresh = useCallback(async () => {
    const currentRequest = ++requestId.current;
    avatarRetries.current = 0;

    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (currentRequest !== requestId.current) return;

      if (!session?.user) {
        setSignedIn(false);
        setFirstName("Member");
        setRecoveriesCount(0);
        setAvatarUrl(null);
        return;
      }

      setSignedIn(true);

      const [{ data: profile }, { data: responder }] = await Promise.all([
        supabase
          .from("profiles")
          .select("display_name")
          .eq("user_id", session.user.id)
          .maybeSingle(),
        supabase.rpc("my_responder_profile"),
      ]);
      if (currentRequest !== requestId.current) return;

      const responderProfile = responder as ResponderProfile;
      const displayName =
        responderProfile?.first_name?.trim() ||
        profile?.display_name?.trim() ||
        (typeof session.user.user_metadata?.full_name === "string"
          ? session.user.user_metadata.full_name.trim()
          : "") ||
        session.user.email?.split("@")[0] ||
        "Member";

      setFirstName(displayName.split(/\s+/)[0] || "Member");
      setRecoveriesCount(responderProfile?.recoveries_count ?? 0);
      await signOwnAvatar(session.access_token);
    } catch {
      if (currentRequest !== requestId.current) return;
      setSignedIn(false);
      setFirstName("Member");
      setRecoveriesCount(0);
      setAvatarUrl(null);
    }
  }, [signOwnAvatar]);

  const retryExpiredAvatar = useCallback(async () => {
    if (avatarRetries.current > 0) {
      setAvatarUrl(null);
      return;
    }
    avatarRetries.current += 1;

    const { data: { session } } = await supabase.auth.getSession();
    if (!session?.user) {
      setAvatarUrl(null);
      return;
    }
    await signOwnAvatar(session.access_token);
  }, [signOwnAvatar]);

  useEffect(() => {
    void refresh();

    const { data: { subscription } } = supabase.auth.onAuthStateChange((event) => {
      if (event === "SIGNED_IN" || event === "SIGNED_OUT" || event === "TOKEN_REFRESHED") {
        setTimeout(() => void refresh(), 0);
      }
    });
    const appState = AppState.addEventListener("change", (state) => {
      if (state === "active") void refresh();
    });

    return () => {
      requestId.current += 1;
      subscription.unsubscribe();
      appState.remove();
    };
  }, [refresh]);

  return { signedIn, firstName, recoveriesCount, avatarUrl, refresh, retryExpiredAvatar };
}
