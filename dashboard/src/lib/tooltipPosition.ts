/** Gap kept between a tooltip and its anchor, and between a tooltip and the viewport edge. */
const MARGIN = 8;

interface Rect {
  left: number;
  top: number;
  width: number;
  bottom: number;
}

/**
 * Where to put a fixed-position tooltip: centred under its anchor, clamped
 * inside the viewport, flipped above when it would run off the bottom and
 * there is room above. Width shrinks to fit narrow screens.
 */
export function placeTooltip(
  anchor: Rect,
  tip: { width: number; height: number },
  viewport: { width: number; height: number },
): { left: number; top: number; width: number } {
  const width = Math.min(tip.width, viewport.width - 2 * MARGIN);
  const centred = anchor.left + anchor.width / 2 - width / 2;
  const left = Math.min(Math.max(centred, MARGIN), viewport.width - width - MARGIN);

  const below = anchor.bottom + MARGIN;
  const above = anchor.top - MARGIN - tip.height;
  const fitsBelow = below + tip.height <= viewport.height - MARGIN;
  const top = !fitsBelow && above >= MARGIN ? above : below;

  return { left, top, width };
}
