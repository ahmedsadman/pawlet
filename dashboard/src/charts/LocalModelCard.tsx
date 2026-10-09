import {
  CartesianGrid,
  Line,
  LineChart,
  ReferenceLine,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import type { LocalModel } from "../api/types";
import { Card } from "../components/Card";
import { fmtDay, fmtPercent } from "../lib/format";
import {
  fmtDayDetail,
  fmtModelErrors,
  fmtPointDelta,
  fmtRate,
  fmtSplit,
  localModelRows,
  ringArc,
  type LocalModelRow,
} from "../lib/localModel";
import { AXIS, SERIES, ctp } from "../theme/tokens";

const RING_SIZE = 128;
const RING_STROKE = 10;
const RING_RADIUS = (RING_SIZE - RING_STROKE) / 2;
const RING_CIRCUMFERENCE = 2 * Math.PI * RING_RADIUS;
const TONE_CLASS = {
  up: "text-ctp-green",
  down: "text-ctp-red",
  flat: "text-ctp-subtext0",
} as const;

/** Screen-reader name for the ring, which is otherwise only a drawn arc. */
function ringLabel(rate: number | null): string {
  return rate == null ? "No on-device data" : `${fmtRate(rate)} of messages handled on device`;
}

/**
 * Ring with the range's on-device rate, its change against the previous
 * period, and the counts behind it. The track is surface1 because the card
 * itself is surface0.
 */
export function LocalModelSummary({ lm }: { lm: LocalModel }) {
  const arc = ringArc(lm.rate, RING_CIRCUMFERENCE);
  const delta = fmtPointDelta(lm.rate, lm.prevRate);
  const errors = fmtModelErrors(lm.unavailable);
  const c = RING_SIZE / 2;
  return (
    <div className="flex flex-col items-center gap-1.5 text-center">
      <div className="relative" style={{ width: RING_SIZE, height: RING_SIZE }}>
        <svg
          width={RING_SIZE}
          height={RING_SIZE}
          viewBox={`0 0 ${RING_SIZE} ${RING_SIZE}`}
          role="img"
          aria-label={ringLabel(lm.rate)}
        >
          <circle
            cx={c}
            cy={c}
            r={RING_RADIUS}
            fill="none"
            stroke={ctp.surface1}
            strokeWidth={RING_STROKE}
          />
          {arc > 0 && (
            <circle
              cx={c}
              cy={c}
              r={RING_RADIUS}
              fill="none"
              stroke={SERIES[0]}
              strokeWidth={RING_STROKE}
              strokeLinecap="round"
              strokeDasharray={`${arc} ${RING_CIRCUMFERENCE}`}
              transform={`rotate(-90 ${c} ${c})`}
            />
          )}
        </svg>
        <div className="absolute inset-0 flex flex-col items-center justify-center">
          <span className="tabular text-2xl font-semibold text-ctp-text">{fmtRate(lm.rate)}</span>
          <span className="text-xs text-ctp-subtext0">on device</span>
        </div>
      </div>
      {delta && (
        <span className={`text-xs ${TONE_CLASS[delta.tone]}`}>{delta.text} vs previous period</span>
      )}
      <span className="tabular text-xs text-ctp-subtext1">
        {fmtSplit(lm.accepted, lm.declined)}
      </span>
      {errors && <span className="tabular text-xs text-ctp-subtext0">{errors}</span>}
    </div>
  );
}

function LocalModelTooltip({ active, row }: { active?: boolean; row?: LocalModelRow }) {
  if (!active || !row) return null;
  return (
    <div className="rounded-lg bg-ctp-mantle px-3 py-2 text-xs shadow-xl ring-1 ring-ctp-surface1">
      <div className="mb-1 font-medium text-ctp-subtext1">{fmtDay(row.day)}</div>
      <div className="tabular text-ctp-text">{fmtDayDetail(row)}</div>
    </div>
  );
}

/**
 * The weighted 7-day rate as a 2px line over faint daily dots, one y-axis in
 * percent, with a dashed line on each day a new app version took over.
 */
export function LocalModelChart({ lm, height = 220 }: { lm: LocalModel; height?: number }) {
  const rows = localModelRows(lm);
  return (
    <div className="min-w-0">
      <ul className="mb-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-ctp-subtext1">
        <li className="flex items-center gap-1.5">
          <span
            className="h-0.5 w-3 rounded-full"
            style={{ backgroundColor: SERIES[0] }}
            aria-hidden
          />
          7-day average
        </li>
        <li className="flex items-center gap-1.5">
          <span
            className="size-2 rounded-full opacity-35"
            style={{ backgroundColor: SERIES[0] }}
            aria-hidden
          />
          daily
        </li>
        <li className="flex items-center gap-1.5">
          <span className="w-3 border-t border-dashed border-ctp-overlay1" aria-hidden />
          new app version
        </li>
      </ul>
      <div style={{ height }}>
        <ResponsiveContainer width="100%" height="100%">
          <LineChart data={rows} margin={{ top: 16, right: 8, bottom: 0, left: 0 }}>
            <CartesianGrid stroke={AXIS.grid} vertical={false} />
            <XAxis
              dataKey="day"
              tickFormatter={fmtDay}
              tick={{ fill: AXIS.tick, fontSize: 11 }}
              stroke={AXIS.line}
              tickLine={false}
              minTickGap={28}
            />
            <YAxis
              tickFormatter={(v: number) => fmtPercent(v, 0)}
              tick={{ fill: AXIS.tick, fontSize: 11 }}
              axisLine={false}
              tickLine={false}
              width={52}
              domain={[0, 1]}
            />
            <Tooltip
              cursor={{ stroke: ctp.overlay0, strokeWidth: 1 }}
              content={(p) => (
                <LocalModelTooltip
                  active={p.active}
                  row={p.payload?.[0]?.payload as LocalModelRow | undefined}
                />
              )}
            />
            {lm.versionMarkers.map((m) => (
              <ReferenceLine
                key={m.day}
                x={m.day}
                stroke={ctp.overlay1}
                strokeDasharray="4 4"
                label={{
                  value: `v${m.appVersionCode}`,
                  position: "top",
                  fill: AXIS.tick,
                  fontSize: 10,
                }}
              />
            ))}
            <Line
              dataKey="daily"
              name="Daily"
              stroke="none"
              dot={{ r: 2.5, fill: SERIES[0], fillOpacity: 0.35, stroke: "none" }}
              activeDot={false}
              isAnimationActive={false}
            />
            <Line
              dataKey="rolling"
              name="7-day average"
              type="monotone"
              stroke={SERIES[0]}
              strokeWidth={2}
              dot={false}
              activeDot={{ r: 4, stroke: ctp.surface0, strokeWidth: 2 }}
              connectNulls={false}
              isAnimationActive={false}
            />
          </LineChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
}

/** Full-width card: ring on the left, trend on the right; stacks on narrow screens. */
export function LocalModelCard({ lm }: { lm: LocalModel }) {
  const empty = lm.accepted + lm.declined + lm.unavailable === 0;
  return (
    <Card title="Local model" statId="chart.localModel">
      <div className="grid items-center gap-6 md:grid-cols-[auto_minmax(0,1fr)]">
        <LocalModelSummary lm={lm} />
        {empty ? (
          <p className="text-sm text-ctp-subtext0">No message counts in this range.</p>
        ) : (
          <LocalModelChart lm={lm} />
        )}
      </div>
    </Card>
  );
}
