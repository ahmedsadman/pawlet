# Design

## Theme

Catppuccin Macchiato, matching the mobile app (`mobile-app/lib/theme/catppuccin_theme.dart`).
Tokens are declared in `src/index.css` as `ctp-*` Tailwind colors.

Roles:

- **base** — page background
- **mantle** — sidebar
- **surface0** — cards
- **mauve** — primary accent

## Chart colors

Declared in `src/theme/tokens.ts`.

The six series colors are Catppuccin hues stepped darker because the pastel originals fail
lightness, chroma and colorblind-separation checks on the dark card surface. They were validated:
lightness band, chroma floor, colorblind ΔE ≥ 8, normal-vision ΔE ≥ 15, contrast ≥ 3:1.

Assign in order, never cycle: extra series fold into "Other".

Status colors (pastel green, yellow, peach, red) have reserved meaning and always appear with a
legend label.

The cohort heatmap uses a validated mauve ramp.

## Chart rules

- One y-axis per chart
- Failures plotted separately from the success rate
- Legends for two or more series
- Text never in series colors

## Stat tooltips

Every stat's ⓘ text lives in `src/copy/stats.ts`, typed so a stat without copy fails the typecheck.
Wording must agree with `server/docs/metrics.md` ("Dashboard definitions"). A unit test checks
every entry is filled.

## Snapshot of color values

From `src/theme/tokens.ts` as of this writing; verify against the source.

| Name            | Value                    | Use                              |
| --------------- | ------------------------ | -------------------------------- |
| SERIES[0]       | `#a47dd3`                | First categorical series (mauve) |
| SERIES[1]       | `#06a99a`                | Second series (teal)             |
| SERIES[2]       | `#d17843`                | Third series (peach)             |
| SERIES[3]       | `#6990e2`                | Fourth series (blue)             |
| SERIES[4]       | `#b78b16`                | Fifth series (yellow)            |
| SERIES[5]       | `#c371b0`                | Sixth series (pink)              |
| OTHER           | `#6e738d` (ctp.overlay0) | "Other" and "unknown" buckets    |
| STATUS.good     | `#a6da95` (ctp.green)    | Success status                   |
| STATUS.warning  | `#eed49f` (ctp.yellow)   | Warning status                   |
| STATUS.serious  | `#f5a97f` (ctp.peach)    | Serious status                   |
| STATUS.critical | `#ed8796` (ctp.red)      | Critical status                  |
| SEQUENTIAL[0-4] | `#6a638a` to `#c6a0f6`   | Cohort heatmap (low to high)     |
