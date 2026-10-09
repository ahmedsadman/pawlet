import { AlertTriangle } from "lucide-react";
import { ApiError } from "../api/client";

export function ErrorCard({ error, onRetry }: { error: unknown; onRetry?: () => void }) {
  const detail = error instanceof ApiError ? `${error.status} ${error.code}` : "network error";
  return (
    <div
      role="alert"
      className="flex items-center justify-between gap-3 rounded-xl bg-ctp-surface0 p-4 ring-1 ring-ctp-red/40"
    >
      <div className="flex items-center gap-2 text-sm text-ctp-text">
        <AlertTriangle className="size-4 text-ctp-red" aria-hidden />
        Couldn't load this. <span className="text-ctp-subtext0">({detail})</span>
      </div>
      {onRetry && (
        <button
          type="button"
          onClick={onRetry}
          className="rounded-md bg-ctp-surface1 px-3 py-1 text-xs hover:bg-ctp-surface2"
        >
          Retry
        </button>
      )}
    </div>
  );
}
