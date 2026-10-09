import { useEffect, useId, useState } from "react";
import { shortHash } from "../lib/format";

const MAX_REASON = 200;

export function BanDialog({
  hash,
  onClose,
  onConfirm,
  pending,
  error,
}: {
  hash: string;
  onClose: () => void;
  onConfirm: (reason: string) => void;
  pending: boolean;
  error?: string | null;
}) {
  const [reason, setReason] = useState("");
  const titleId = useId();
  const inputId = useId();
  const trimmed = reason.trim();
  const length = [...trimmed].length;
  const valid = length > 0 && length <= MAX_REASON;

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-ctp-crust/70 p-4 backdrop-blur-sm">
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        className="w-full max-w-md rounded-2xl bg-ctp-mantle p-6 shadow-2xl ring-1 ring-ctp-surface0"
      >
        <h2 id={titleId} className="text-lg font-semibold text-ctp-text">
          Ban install <span className="font-mono text-ctp-subtext1">{shortHash(hash)}</span>
        </h2>
        <p className="mt-1 text-sm text-ctp-subtext0">
          Its next session or classify call is refused. You can unban it later.
        </p>
        <form
          className="mt-4"
          onSubmit={(e) => {
            e.preventDefault();
            if (valid && !pending) onConfirm(trimmed);
          }}
        >
          <label htmlFor={inputId} className="text-xs font-medium text-ctp-subtext1">
            Reason
          </label>
          <textarea
            id={inputId}
            autoFocus
            rows={3}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            className="mt-1 w-full resize-none rounded-lg bg-ctp-surface0 p-2 text-sm text-ctp-text ring-1 ring-ctp-surface1 focus:ring-ctp-mauve focus:outline-none"
          />
          <div
            className={`mt-1 text-right text-xs ${length > MAX_REASON ? "text-ctp-red" : "text-ctp-subtext0"}`}
          >
            {length} / {MAX_REASON}
          </div>
          {error && <p className="mt-2 text-sm text-ctp-red">{error}</p>}
          <div className="mt-4 flex justify-end gap-2">
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg px-4 py-2 text-sm text-ctp-subtext1 hover:bg-ctp-surface0"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={!valid || pending}
              className="rounded-lg bg-ctp-red px-4 py-2 text-sm font-medium text-ctp-crust disabled:cursor-not-allowed disabled:opacity-40"
            >
              {pending ? "Banning…" : "Ban install"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
