import type { InstallDetailResponse } from "../api/types";
import { fmtDay } from "../lib/format";
import { SERIES, ctp } from "../theme/tokens";
import { SeriesLegend } from "./SeriesLegend";

const CLASSIFIED = SERIES[0];
const OPENED = SERIES[1];
const BACKGROUND = SERIES[2];

/** One square per day: classified, opened, ran in the background only, or idle. Last 120 days. */
export function ActivityStrip({ daily }: { daily: InstallDetailResponse["daily"] }) {
  const days = daily.slice(-120);
  return (
    <div>
      <SeriesLegend
        series={[
          { key: "c", label: "Classified", color: CLASSIFIED },
          { key: "o", label: "Opened", color: OPENED },
          { key: "b", label: "Background only", color: BACKGROUND },
          { key: "i", label: "Idle", color: ctp.surface1 },
        ]}
      />
      <div className="flex flex-wrap gap-0.5">
        {days.map((d) => {
          // Sessions are only minted in the foreground, so a session day
          // counts as opened (it covers days before heartbeats existed).
          const [color, what] =
            d.calls > 0
              ? [CLASSIFIED, `${d.calls} calls`]
              : d.opened || d.session
                ? [OPENED, "opened, no calls"]
                : d.alive
                  ? [BACKGROUND, "ran in the background"]
                  : [ctp.surface1, "idle"];
          return (
            <span
              key={d.day}
              title={`${fmtDay(d.day)}: ${what}`}
              className="size-3 rounded-sm"
              style={{ backgroundColor: color }}
            />
          );
        })}
      </div>
    </div>
  );
}
