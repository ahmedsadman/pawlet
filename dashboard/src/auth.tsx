import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, type ReactNode } from "react";
import { Navigate, useLocation, useNavigate, type Location } from "react-router";
import { api, ApiError, UNAUTHORIZED_EVENT } from "./api/client";
import { ErrorCard } from "./components/ErrorCard";

export function loginPath(location: Pick<Location, "pathname" | "search">): string {
  const next = location.pathname + location.search;
  return next === "/" || next.startsWith("/login")
    ? "/login"
    : `/login?next=${encodeURIComponent(next)}`;
}

/** Only same-app relative paths are allowed as a post-login destination. */
export function safeNext(next: string | null): string {
  return next && next.startsWith("/") && !next.startsWith("//") ? next : "/";
}

export function RequireAuth({ children }: { children: ReactNode }) {
  const location = useLocation();
  const me = useQuery({ queryKey: ["me"], queryFn: api.me, retry: false, staleTime: 5 * 60_000 });
  if (me.isPending) {
    return (
      <div className="grid min-h-dvh place-items-center text-sm text-ctp-subtext0">Loading…</div>
    );
  }
  if (me.isError) {
    if (me.error instanceof ApiError && me.error.status === 401) {
      return <Navigate to={loginPath(location)} replace />;
    }
    return (
      <div className="p-8">
        <ErrorCard error={me.error} onRetry={() => void me.refetch()} />
      </div>
    );
  }
  return <>{children}</>;
}

/** Sends the user to login when any request reports an expired session. */
export function AuthWatcher() {
  const navigate = useNavigate();
  const location = useLocation();
  const client = useQueryClient();
  useEffect(() => {
    const onUnauthorized = () => {
      if (location.pathname === "/login") return;
      client.removeQueries();
      navigate(loginPath(location), { replace: true });
    };
    window.addEventListener(UNAUTHORIZED_EVENT, onUnauthorized);
    return () => window.removeEventListener(UNAUTHORIZED_EVENT, onUnauthorized);
  }, [client, location, navigate]);
  return null;
}
