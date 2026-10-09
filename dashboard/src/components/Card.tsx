import type { ReactNode } from "react";
import type { StatId } from "../copy/stats";
import { InfoTip } from "./InfoTip";

export function Card({
  title,
  statId,
  actions,
  children,
  className = "",
}: {
  title?: string;
  statId?: StatId;
  actions?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section className={`rounded-xl bg-ctp-surface0 p-4 ring-1 ring-ctp-surface1/40 ${className}`}>
      {(title || actions) && (
        <header className="mb-3 flex items-center justify-between gap-2">
          <h2 className="flex items-center gap-1.5 text-sm font-medium text-ctp-subtext1">
            {title}
            {statId && <InfoTip id={statId} />}
          </h2>
          {actions}
        </header>
      )}
      {children}
    </section>
  );
}
