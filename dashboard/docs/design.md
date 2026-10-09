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

## Message counts

Installs on recent app versions report how many messages the on-device model handled; the UI shows
them next to LLM calls:

- **Reliability** opens with a full-width **Local model** card (`src/charts/LocalModelCard.tsx`): a
  ring with the on-device rate, its change in points against the previous period, the counts
  behind it and any model errors; beside it, the 7-day average as a line over faint daily dots, with
  a dashed line on each day a new app version took over. A footer at the bottom of the page totals messages
  (on device and via LLM) and successful LLM calls. The ring's track is `surface1` because the
  card itself is `surface0`.
- **Installs**: the Today, 7 days and Total columns show messages with LLM calls muted underneath
  (`src/components/MessagesCell.tsx`; `—` for installs without model stats) and sort by messages.
- **Install detail**: "Messages and calls per day" line chart.
- **Engagement**: "Messages per active day" histogram, noted as covering the last 90 days only on
  the "All" range.
- **Overview**: "Messages per day" line chart (messages and LLM calls), and "Messages per active
  install-day" with calls in brackets on the Server card.

Messages and calls share line charts rather than stacked bars, because stacking would add calls on
top of the messages they belong to.

Every messages stat's tooltip names the first app release that reports message counts through
`MESSAGE_COUNTS_RELEASE` in `src/copy/stats.ts`. Whoever cuts that release must set it to
`"app version <versionCode>"`.

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
