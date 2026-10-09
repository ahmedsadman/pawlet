import { fmtCount } from "../lib/format";

/**
 * Installs table cell: messages as the main number, LLM calls muted
 * underneath. "—" for installs that never reported message counts (older app
 * versions), never a false 0.
 */
export function MessagesCell({
  messages,
  calls,
  hasStats,
}: {
  messages: number;
  calls: number;
  hasStats: boolean;
}) {
  return (
    <span className="inline-flex flex-col items-end leading-tight">
      <span className="text-ctp-text">{hasStats ? fmtCount(messages) : "—"}</span>
      <span className="text-xs text-ctp-subtext0">{fmtCount(calls)} LLM</span>
    </span>
  );
}
