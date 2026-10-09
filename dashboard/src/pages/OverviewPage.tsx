import { Async } from "../components/Async";
import { Card } from "../components/Card";
import { Meter } from "../components/Meter";
import { PageHeader } from "../components/PageHeader";
import { RangePicker } from "../components/RangePicker";
import { Skeleton } from "../components/Skeleton";
import { StatTile } from "../components/StatTile";
import { TimeSeriesChart } from "../charts/TimeSeriesChart";
import { InfoTip } from "../components/InfoTip";
import { useOverview } from "../api/queries";
import { fmtAgo, fmtCount, fmtDelta, fmtPerInstallDay, fmtPercent } from "../lib/format";
import { useRange } from "../lib/range";
import { SERIES } from "../theme/tokens";

export default function OverviewPage() {
  const [range] = useRange();
  const query = useOverview(range);
  return (
    <>
      <PageHeader title="Overview">
        <RangePicker />
      </PageHeader>
      <Async
        query={query}
        skeleton={
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            {Array.from({ length: 8 }, (_, i) => (
              <Skeleton key={i} className="h-28" />
            ))}
          </div>
        }
      >
        {(d) => {
          const k = d.kpis;
          return (
            <div className="space-y-6">
              <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
                <StatTile
                  label="Attested installs"
                  statId="attestedInstalls"
                  value={fmtCount(k.attestedInstalls)}
                  sub={k.banned > 0 ? `${k.banned} banned` : undefined}
                />
                <StatTile
                  label="New installs"
                  statId="newInstalls"
                  value={fmtCount(k.newInstalls)}
                  // "All" has no previous period: the comparison window lies before any data.
                  delta={range === "all" ? null : fmtDelta(k.newInstalls, k.newInstallsPrev)}
                  sub={range === "all" ? undefined : "vs previous period"}
                />
                <StatTile label="Daily active" statId="dau.any" value={fmtCount(k.dau)} />
                <StatTile label="Weekly active" statId="wau.any" value={fmtCount(k.wau)} />
                <StatTile label="Monthly active" statId="mau.any" value={fmtCount(k.mau)} />
                <div className="rounded-xl bg-ctp-surface0 p-4 ring-1 ring-ctp-surface1/40">
                  <StatTileHeader />
                  <div className="mt-1.5 text-2xl font-semibold">{fmtCount(k.callsToday)}</div>
                  <Meter
                    value={k.callsToday}
                    max={d.server.globalDailyCap}
                    label="Share of the global daily cap used"
                  />
                  <div className="mt-1 text-xs text-ctp-subtext0">
                    of {fmtCount(d.server.globalDailyCap)} global cap
                  </div>
                </div>
                <StatTile
                  label="Tokens today"
                  statId="tokensToday"
                  value={fmtCount(k.tokensToday)}
                />
                <StatTile
                  label="LLM success today"
                  statId="successRateToday"
                  value={fmtPercent(k.successRateToday)}
                />
              </div>

              <div className="grid gap-4 lg:grid-cols-2">
                <Card title="Messages per day" statId="chart.messagesPerDay">
                  <TimeSeriesChart
                    data={d.daily}
                    series={[
                      { key: "messages", label: "Messages", color: SERIES[0] },
                      { key: "calls", label: "LLM calls", color: SERIES[1] },
                    ]}
                  />
                </Card>
                <Card title="Active installs per day" statId="chart.activeInstallsPerDay">
                  <TimeSeriesChart
                    data={d.daily}
                    kind="area"
                    series={[{ key: "activeInstalls", label: "Active installs", color: SERIES[1] }]}
                  />
                </Card>
                <Card title="New installs per day" statId="chart.newInstallsPerDay">
                  <TimeSeriesChart
                    data={d.daily}
                    kind="bar"
                    series={[{ key: "newInstalls", label: "New installs", color: SERIES[3] }]}
                  />
                </Card>
                <Card title="Server" statId="serverInfo">
                  <dl className="grid grid-cols-2 gap-x-6 gap-y-3 text-sm">
                    <Fact
                      label="Daily limit per install"
                      value={fmtCount(d.server.dailyPerInstall)}
                    />
                    <Fact label="Burst per minute" value={fmtCount(d.server.burstPerMin)} />
                    <Fact label="Global daily cap" value={fmtCount(d.server.globalDailyCap)} />
                    <Fact
                      label="Messages per active install-day"
                      value={fmtPerInstallDay(
                        k.messagesPerActiveInstallDay,
                        k.callsPerActiveInstallDay,
                      )}
                      statId="messagesPerActiveInstallDay"
                    />
                    <Fact
                      label="Started"
                      value={d.server.startedAt ? fmtAgo(d.server.startedAt) : "—"}
                    />
                    <Fact
                      label="Image"
                      value={d.server.imageTag ? d.server.imageTag.slice(0, 12) : "—"}
                      mono
                    />
                    <div className="col-span-2">
                      <dt className="text-xs text-ctp-subtext0">Models, in fallback order</dt>
                      <dd className="mt-1 space-y-0.5 font-mono text-xs text-ctp-text">
                        {d.server.models.length
                          ? d.server.models.map((m) => <div key={m}>{m}</div>)
                          : "—"}
                      </dd>
                    </div>
                  </dl>
                </Card>
              </div>
            </div>
          );
        }}
      </Async>
    </>
  );
}

function StatTileHeader() {
  return (
    <div className="flex items-center gap-1.5 text-xs font-medium tracking-wide text-ctp-subtext0 uppercase">
      Calls today
      <InfoTip id="callsToday" />
    </div>
  );
}

function Fact({
  label,
  value,
  mono = false,
  statId,
}: {
  label: string;
  value: string;
  mono?: boolean;
  statId?: "messagesPerActiveInstallDay";
}) {
  return (
    <div>
      <dt className="flex items-center gap-1 text-xs text-ctp-subtext0">
        {label}
        {statId && <InfoTip id={statId} />}
      </dt>
      <dd className={`mt-0.5 text-ctp-text ${mono ? "font-mono text-xs" : ""}`}>{value}</dd>
    </div>
  );
}
