import { useFleet } from "../api/queries";
import { BarList } from "../charts/BarList";
import { TimeSeriesChart } from "../charts/TimeSeriesChart";
import { Async } from "../components/Async";
import { Card } from "../components/Card";
import { CollectingNote } from "../components/CollectingNote";
import { PageHeader } from "../components/PageHeader";
import { Skeleton } from "../components/Skeleton";
import { StatTile } from "../components/StatTile";
import { fmtCount } from "../lib/format";
import { topVersionSeries } from "../lib/series";

export default function FleetPage() {
  const query = useFleet();
  return (
    <>
      <PageHeader title="Fleet" />
      <Async query={query} skeleton={<Skeleton className="h-96" />}>
        {(d) => {
          const adoption = topVersionSeries(d.adoption, 5);
          const adoptionFrom = d.adoption[0]?.day ?? "";
          return (
            <div className="space-y-6">
              <div className="grid gap-4 sm:grid-cols-3">
                <StatTile
                  label="Recently active installs"
                  statId="fleetActive"
                  value={fmtCount(d.activeInstalls)}
                  sub="last 30 days"
                />
              </div>
              <div className="grid gap-4 lg:grid-cols-2">
                <Card title="App versions" statId="chart.versions">
                  <BarList
                    items={d.versions}
                    labelFor={(k) => (k === "unknown" ? "unknown" : `v${k}`)}
                  />
                </Card>
                <Card title="Version adoption" statId="chart.adoption">
                  <CollectingNote since={d.collectingSince.sessions} rangeFrom={adoptionFrom} />
                  <TimeSeriesChart data={adoption.rows} kind="bar" series={adoption.series} />
                </Card>
                <Card title="Device tier" statId="chart.tier">
                  <BarList items={d.deviceTier} />
                </Card>
                <Card title="Licensing" statId="chart.licensing">
                  <BarList items={d.licensing} />
                </Card>
                <Card title="Android SDK" statId="chart.sdk">
                  <BarList
                    items={d.sdk}
                    labelFor={(k) => (k === "unknown" ? "unknown" : `API ${k}`)}
                  />
                </Card>
              </div>
            </div>
          );
        }}
      </Async>
    </>
  );
}
