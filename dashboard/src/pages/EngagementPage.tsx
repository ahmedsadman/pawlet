import { Link, useSearchParams } from "react-router";
import { useEngagement } from "../api/queries";
import type { ActiveMode } from "../api/types";
import { CohortHeatmap } from "../charts/CohortHeatmap";
import { Histogram } from "../charts/Histogram";
import { TimeSeriesChart } from "../charts/TimeSeriesChart";
import { Async } from "../components/Async";
import { Card } from "../components/Card";
import { CollectingNote } from "../components/CollectingNote";
import { PageHeader } from "../components/PageHeader";
import { RangePicker } from "../components/RangePicker";
import { Segmented } from "../components/Segmented";
import { Skeleton } from "../components/Skeleton";
import { StatTile } from "../components/StatTile";
import { fmtCount, fmtPercent } from "../lib/format";
import { useRange } from "../lib/range";
import { SERIES } from "../theme/tokens";

const MODES: { key: ActiveMode; label: string }[] = [
  { key: "any", label: "Any activity" },
  { key: "classify", label: "Classify only" },
];

export default function EngagementPage() {
  const [range] = useRange();
  const [params, setParams] = useSearchParams();
  const mode: ActiveMode = params.get("active") === "classify" ? "classify" : "any";
  const query = useEngagement(range, mode);
  const setMode = (m: ActiveMode) =>
    setParams(
      (prev) => {
        const next = new URLSearchParams(prev);
        if (m === "any") next.delete("active");
        else next.set("active", m);
        return next;
      },
      { replace: true },
    );

  return (
    <>
      <PageHeader title="Engagement">
        <Segmented label="What counts as active" options={MODES} value={mode} onChange={setMode} />
        <RangePicker />
      </PageHeader>
      <Async query={query} skeleton={<Skeleton className="h-96" />}>
        {(d) => (
          <div className="space-y-6">
            {mode === "any" && (
              <CollectingNote since={d.collectingSince.sessions} rangeFrom={d.range.from} />
            )}
            <div className="grid gap-4 lg:grid-cols-2">
              <Card
                title="Active installs"
                statId={mode === "any" ? "chart.active.any" : "chart.active.classify"}
              >
                <TimeSeriesChart
                  data={d.daily.map(({ day, dau, wau, mau }) => ({ day, dau, wau, mau }))}
                  series={[
                    { key: "dau", label: "Daily", color: SERIES[0] },
                    { key: "wau", label: "Weekly", color: SERIES[1] },
                    { key: "mau", label: "Monthly", color: SERIES[2] },
                  ]}
                />
              </Card>
              <Card
                title="Stickiness"
                statId={mode === "any" ? "chart.stickiness.any" : "chart.stickiness.classify"}
              >
                <TimeSeriesChart
                  data={d.daily.map(({ day, stickiness }) => ({ day, stickiness }))}
                  kind="area"
                  percent
                  yFormat={(v) => fmtPercent(v, 0)}
                  series={[{ key: "stickiness", label: "DAU ÷ MAU", color: SERIES[0] }]}
                />
              </Card>
            </div>
            <Card
              title="Weekly retention"
              statId={mode === "any" ? "chart.cohorts.any" : "chart.cohorts.classify"}
            >
              <CohortHeatmap cohorts={d.cohorts} />
            </Card>
            <div className="grid gap-4 lg:grid-cols-[2fr_1fr]">
              <Card title="Messages per active day" statId="chart.messagesDistribution">
                {range === "all" && (
                  <p className="mb-2 text-xs text-ctp-subtext0">Covers the last 90 days only.</p>
                )}
                <Histogram data={d.messagesDistribution} unit="messages" />
              </Card>
              <div className="space-y-4">
                <StatTile label="Dormant installs" statId="dormant" value={fmtCount(d.dormant)} />
                <Link
                  to="/installs?status=dormant"
                  className="block text-sm text-ctp-mauve hover:underline"
                >
                  View dormant installs →
                </Link>
              </div>
            </div>
          </div>
        )}
      </Async>
    </>
  );
}
