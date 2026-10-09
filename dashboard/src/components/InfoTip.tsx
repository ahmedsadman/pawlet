import { Info } from "lucide-react";
import { useEffect, useId, useRef, useState } from "react";
import { statCopy, type StatId } from "../copy/stats";

/** ⓘ button that explains a stat. Opens on hover, focus or tap; closes on Escape or an outside tap. */
export function InfoTip({ id }: { id: StatId }) {
  const entry: { title: string; meaning: string; computation: string; caveat?: string } =
    statCopy[id];
  const [open, setOpen] = useState(false);
  const tipId = useId();
  const root = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    const onPointer = (e: PointerEvent) => {
      if (!root.current?.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("keydown", onKey);
    document.addEventListener("pointerdown", onPointer);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.removeEventListener("pointerdown", onPointer);
    };
  }, [open]);

  return (
    <span
      ref={root}
      className="relative inline-flex align-middle"
      onMouseEnter={() => setOpen(true)}
      onMouseLeave={() => setOpen(false)}
    >
      <button
        type="button"
        aria-label={`About ${entry.title}`}
        aria-describedby={open ? tipId : undefined}
        aria-expanded={open}
        onFocus={() => setOpen(true)}
        onBlur={() => setOpen(false)}
        // Opens rather than toggles: on touch, focus and click both fire.
        onClick={() => setOpen(true)}
        className="rounded-full p-0.5 text-ctp-overlay1 transition-colors hover:text-ctp-subtext1"
      >
        <Info className="size-3.5" aria-hidden />
      </button>
      {open && (
        <span
          role="tooltip"
          id={tipId}
          className="absolute top-full left-1/2 z-50 mt-2 w-72 max-w-[calc(100vw-2rem)] -translate-x-1/2 rounded-lg bg-ctp-surface1 p-3 text-left text-xs leading-relaxed font-normal text-ctp-text shadow-xl ring-1 ring-ctp-surface2"
        >
          <span className="block">{entry.meaning}</span>
          <span className="mt-1.5 block text-ctp-subtext1">{entry.computation}</span>
          {entry.caveat && <span className="mt-1.5 block text-ctp-subtext0">{entry.caveat}</span>}
        </span>
      )}
    </span>
  );
}
