import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { fmtCount, fmtDay } from "../lib/format";
import { AXIS, ctp } from "../theme/tokens";
import { ChartTooltip } from "./ChartTooltip";
import { SeriesLegend } from "./SeriesLegend";

export interface Series {
  key: string;
  label: string;
  color: string;
}

type Row = Record<string, string | number | null>;

/**
 * Daily chart. kind "bar" stacks when given several series (2px surface gaps,
 * rounded top); "line" draws 2px lines; "area" is a single line over a 10%
 * wash. One y-axis only: never mix measures of different scale.
 */
export function TimeSeriesChart({
  data,
  series,
  kind = "line",
  height = 220,
  yFormat = fmtCount,
  percent = false,
}: {
  data: Row[];
  series: Series[];
  kind?: "line" | "bar" | "area";
  height?: number;
  yFormat?: (v: number) => string;
  percent?: boolean;
}) {
  const xAxis = (
    <XAxis
      dataKey="day"
      tickFormatter={fmtDay}
      tick={{ fill: AXIS.tick, fontSize: 11 }}
      stroke={AXIS.line}
      tickLine={false}
      minTickGap={28}
    />
  );
  const yAxis = (
    <YAxis
      tickFormatter={yFormat}
      tick={{ fill: AXIS.tick, fontSize: 11 }}
      axisLine={false}
      tickLine={false}
      width={52}
      allowDecimals={percent}
      domain={percent ? [0, 1] : [0, "auto"]}
    />
  );
  const grid = <CartesianGrid stroke={AXIS.grid} vertical={false} />;
  const tooltip = (
    <Tooltip
      cursor={
        kind === "bar"
          ? { fill: ctp.surface1, opacity: 0.35 }
          : { stroke: ctp.overlay0, strokeWidth: 1 }
      }
      content={(p) => (
        <ChartTooltip
          active={p.active}
          payload={p.payload as never}
          label={p.label as string}
          format={yFormat}
        />
      )}
    />
  );
  const margin = { top: 6, right: 8, bottom: 0, left: 0 };

  let chart;
  if (kind === "bar") {
    chart = (
      <BarChart data={data} margin={margin}>
        {grid}
        {xAxis}
        {yAxis}
        {tooltip}
        {series.map((s, i) => (
          <Bar
            key={s.key}
            dataKey={s.key}
            name={s.label}
            stackId="stack"
            fill={s.color}
            stroke={ctp.surface0}
            strokeWidth={series.length > 1 ? 2 : 0}
            maxBarSize={24}
            radius={i === series.length - 1 ? [4, 4, 0, 0] : 0}
            isAnimationActive={false}
          />
        ))}
      </BarChart>
    );
  } else if (kind === "area") {
    const s = series[0];
    chart = (
      <AreaChart data={data} margin={margin}>
        {grid}
        {xAxis}
        {yAxis}
        {tooltip}
        <Area
          dataKey={s.key}
          name={s.label}
          type="monotone"
          stroke={s.color}
          strokeWidth={2}
          fill={s.color}
          fillOpacity={0.1}
          dot={false}
          activeDot={{ r: 4, stroke: ctp.surface0, strokeWidth: 2 }}
          connectNulls={false}
          isAnimationActive={false}
        />
      </AreaChart>
    );
  } else {
    chart = (
      <LineChart data={data} margin={margin}>
        {grid}
        {xAxis}
        {yAxis}
        {tooltip}
        {series.map((s) => (
          <Line
            key={s.key}
            dataKey={s.key}
            name={s.label}
            type="monotone"
            stroke={s.color}
            strokeWidth={2}
            dot={false}
            activeDot={{ r: 4, stroke: ctp.surface0, strokeWidth: 2 }}
            connectNulls={false}
            isAnimationActive={false}
          />
        ))}
      </LineChart>
    );
  }

  return (
    <div>
      {series.length > 1 && <SeriesLegend series={series} />}
      <div style={{ height }}>
        <ResponsiveContainer width="100%" height="100%">
          {chart}
        </ResponsiveContainer>
      </div>
    </div>
  );
}
