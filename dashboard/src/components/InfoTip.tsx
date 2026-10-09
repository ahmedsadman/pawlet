import { Info } from "lucide-react";
import { useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { statCopy, type StatId } from "../copy/stats";
import { placeTooltip } from "../lib/tooltipPosition";

/** Tooltip width in px (matches Tailwind's w-72). */
const TIP_WIDTH = 288;

/**
 * ⓘ button that explains a stat. Opens on hover, focus or tap; closes on
 * Escape or an outside tap. The tooltip is portalled to <body> with fixed
 * positioning so scrolling containers (like the installs table) cannot clip
 * it, and it is kept inside the viewport.
 */
export function InfoTip({ id }: { id: StatId }) {
  const entry: { title: string; meaning: string; computation: string; caveat?: string } =
    statCopy[id];
  const [open, setOpen] = useState(false);
  const [place, setPlace] = useState<{ left: number; top: number; width: number } | null>(null);
  const tipId = useId();
  const root = useRef<HTMLSpanElement>(null);
  const button = useRef<HTMLButtonElement>(null);
  const tip = useRef<HTMLSpanElement>(null);

  useLayoutEffect(() => {
    if (!open) return;
    const update = () => {
      if (!button.current) return;
      setPlace(
        placeTooltip(
          button.current.getBoundingClientRect(),
          { width: TIP_WIDTH, height: tip.current?.offsetHeight ?? 0 },
          { width: window.innerWidth, height: window.innerHeight },
        ),
      );
    };
    update();
    // Capture phase so scrolling any ancestor, not just the window, re-anchors it.
    window.addEventListener("scroll", update, true);
    window.addEventListener("resize", update);
    return () => {
      window.removeEventListener("scroll", update, true);
      window.removeEventListener("resize", update);
    };
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    const onPointer = (e: PointerEvent) => {
      const target = e.target as Node;
      if (!root.current?.contains(target) && !tip.current?.contains(target)) setOpen(false);
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
      className="inline-flex align-middle"
      onMouseEnter={() => setOpen(true)}
      onMouseLeave={() => setOpen(false)}
    >
      <button
        ref={button}
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
      {open &&
        createPortal(
          <span
            ref={tip}
            role="tooltip"
            id={tipId}
            style={{
              position: "fixed",
              left: place?.left ?? 0,
              top: place?.top ?? 0,
              width: place?.width ?? TIP_WIDTH,
              // Hidden for the first layout pass, before its height is measured.
              visibility: place ? "visible" : "hidden",
            }}
            className="z-50 block rounded-lg bg-ctp-surface1 p-3 text-left text-xs leading-relaxed font-normal text-ctp-text shadow-xl ring-1 ring-ctp-surface2"
          >
            <span className="block">{entry.meaning}</span>
            <span className="mt-1.5 block text-ctp-subtext1">{entry.computation}</span>
            {entry.caveat && <span className="mt-1.5 block text-ctp-subtext0">{entry.caveat}</span>}
          </span>,
          document.body,
        )}
    </span>
  );
}
