import { useReliability } from "../api/queries";
import { BarList } from "../charts/BarList";
import { LocalModelCard } from "../charts/LocalModelCard";
import { TimeSeriesChart } from "../charts/TimeSeriesChart";
import { Async } from "../components/Async";
import { Card } from "../components/Card";
import { CollectingNote } from "../components/CollectingNote";
import { PageHeader } from "../components/PageHeader";
import { RangePicker } from "../components/RangePicker";
import { Skeleton } from "../components/Skeleton";
import { fmtMs, fmtPercent } from "../lib/format";
import { fmtReliabilityFooter } from "../lib/localModel";
import {
  ATTEST_REASONS,
  CLASSIFY_FAILURES,
  SESSION_FAILURES,
  groupDaily,
  sumKeys,
} from "../lib/outcomes";
import { useRange } from "../lib/range";
import { SERIES, STATUS } from "../theme/tokens";

const CATEGORY_SERIES = [
  { key: "transaction", label: "Transaction", color: SERIES[0] },
  { key: "bill", label: "Bill", color: SERIES[1] },
  { key: "none", label: "Not financial", color: SERIES[2] },
];

export default function ReliabilityPage() {
  const [range] = useRange();
  const query = useReliability(range);
  return (
    <>
      <PageHeader title="Reliability">
        <RangePicker />
      </PageHeader>
      <Async query={query} skeleton={<Skeleton className="h-96" />}>
        {(d) => {
          const failureSeries = (groups: typeof CLASSIFY_FAILURES) =>
            groups.map((g) => ({ key: g.key, label: g.label, color: g.color }));
          return (
            <div className="space-y-6">
              <CollectingNote since={d.collectingSince.counters} rangeFrom={d.range.from} />
              <LocalModelCard lm={d.localModel} />
              <div className="grid gap-4 lg:grid-cols-2">
                <Card title="LLM success rate" statId="chart.successRate">
                  <TimeSeriesChart
                    data={d.successRate.map((r) => ({ day: r.day, value: r.value }))}
                    kind="area"
                    percent
                    yFormat={(v) => fmtPercent(v, 0)}
                    series={[{ key: "value", label: "Success rate", color: STATUS.good }]}
                  />
                </Card>
                <Card title="Failed classify calls" statId="chart.classifyFailures">
                  <TimeSeriesChart
                    data={groupDaily(d.classifyOutcomes, CLASSIFY_FAILURES)}
                    kind="bar"
                    series={failureSeries(CLASSIFY_FAILURES)}
                  />
                </Card>
                <Card title="Classify latency" statId="chart.latency">
                  <TimeSeriesChart
                    data={d.latency}
                    yFormat={fmtMs}
                    series={[
                      { key: "p50", label: "Median (p50)", color: SERIES[0] },
                      { key: "p95", label: "95th percentile", color: SERIES[2] },
                    ]}
                  />
                </Card>
                <Card title="Tokens per call" statId="chart.tokensPerCall">
                  <TimeSeriesChart
                    data={d.tokensPerCall.map((r) => ({ day: r.day, value: r.value }))}
                    kind="area"
                    series={[{ key: "value", label: "Tokens per call", color: SERIES[3] }]}
                  />
                </Card>
                <Card title="Failed sessions" statId="chart.sessionFailures">
                  <TimeSeriesChart
                    data={groupDaily(d.sessionOutcomes, SESSION_FAILURES)}
                    kind="bar"
                    series={failureSeries(SESSION_FAILURES)}
                  />
                </Card>
                <Card title="Why attestation failed" statId="chart.attestReasons">
                  <BarList
                    items={sumKeys(d.sessionOutcomes, ATTEST_REASONS)}
                    color={STATUS.critical}
                    empty="No attestation failures in this range."
                  />
                </Card>
                <Card title="Served model" statId="chart.models">
                  <BarList items={d.models} />
                </Card>
                <Card title="Message categories" statId="chart.categories">
                  <TimeSeriesChart
                    data={d.categories.map((c) => ({
                      day: c.day,
                      transaction: c.counts.transaction ?? 0,
                      bill: c.counts.bill ?? 0,
                      none: c.counts.none ?? 0,
                    }))}
                    kind="bar"
                    series={CATEGORY_SERIES}
                  />
                </Card>
              </div>
              <p className="text-xs text-ctp-subtext0">
                {fmtReliabilityFooter(
                  d.localModel,
                  d.latency.reduce((s, l) => s + l.count, 0),
                )}
              </p>
            </div>
          );
        }}
      </Async>
    </>
  );
}
