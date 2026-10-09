import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import type { Bucket } from "../api/types";
import { fmtCount } from "../lib/format";
import { AXIS, SERIES, ctp } from "../theme/tokens";
import { ChartTooltip } from "./ChartTooltip";

/** Install-days per bucket; unit names what the buckets count, for the tooltip. */
export function Histogram({
  data,
  unit,
  height = 220,
}: {
  data: Bucket[];
  unit: string;
  height?: number;
}) {
  return (
    <div style={{ height }}>
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={data} margin={{ top: 6, right: 8, bottom: 0, left: 0 }}>
          <CartesianGrid stroke={AXIS.grid} vertical={false} />
          <XAxis
            dataKey="label"
            tick={{ fill: AXIS.tick, fontSize: 11 }}
            stroke={AXIS.line}
            tickLine={false}
          />
          <YAxis
            tickFormatter={fmtCount}
            tick={{ fill: AXIS.tick, fontSize: 11 }}
            axisLine={false}
            tickLine={false}
            width={52}
            allowDecimals={false}
          />
          <Tooltip
            cursor={{ fill: ctp.surface1, opacity: 0.35 }}
            content={(p) => (
              <ChartTooltip
                active={p.active}
                payload={p.payload as never}
                label={p.label as string}
                format={fmtCount}
                labelFormat={(l) => `${l} ${unit}`}
              />
            )}
          />
          <Bar
            dataKey="count"
            name="Install-days"
            fill={SERIES[0]}
            maxBarSize={24}
            radius={[4, 4, 0, 0]}
            isAnimationActive={false}
          />
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}
