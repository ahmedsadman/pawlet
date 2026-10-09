/** Catppuccin Macchiato. UI chrome uses the Tailwind ctp-* classes; charts use these. */
export const ctp = {
  crust: "#181926",
  mantle: "#1e2030",
  base: "#24273a",
  surface0: "#363a4f",
  surface1: "#494d64",
  surface2: "#5b6078",
  overlay0: "#6e738d",
  overlay1: "#8087a2",
  subtext0: "#a5adcb",
  subtext1: "#b8c0e0",
  text: "#cad3f5",
  mauve: "#c6a0f6",
  green: "#a6da95",
  yellow: "#eed49f",
  peach: "#f5a97f",
  red: "#ed8796",
} as const;

/**
 * Categorical series colors: Catppuccin mauve, teal, peach, blue, yellow and
 * pink, re-stepped to OKLCH lightness 0.66 so they stay distinct on the dark
 * card surface, including for colorblind readers. Assign in this order and
 * never cycle: a seventh series folds into "Other".
 */
export const SERIES = ["#a47dd3", "#06a99a", "#d17843", "#6990e2", "#b78b16", "#c371b0"] as const;

/** "Other" and "unknown" buckets. */
export const OTHER = ctp.overlay0;

/** Status colors have a reserved meaning and always appear with a label. */
export const STATUS = {
  good: ctp.green,
  warning: ctp.yellow,
  serious: ctp.peach,
  critical: ctp.red,
  neutral: ctp.overlay1,
  muted: ctp.surface2,
} as const;

/** Cohort heatmap, low to high on the dark surface. */
export const SEQUENTIAL = ["#6a638a", "#8072a4", "#9781bf", "#ae90da", "#c6a0f6"] as const;

export const AXIS = { line: ctp.surface1, tick: ctp.subtext0, grid: ctp.surface1 } as const;
