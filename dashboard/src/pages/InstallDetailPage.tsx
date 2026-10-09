import { useMutation, useQueryClient } from "@tanstack/react-query";
import { ArrowLeft } from "lucide-react";
import { useState } from "react";
import { Link, useParams } from "react-router";
import { api, ApiError } from "../api/client";
import { useInstall } from "../api/queries";
import { ActivityStrip } from "../charts/ActivityStrip";
import { TimeSeriesChart } from "../charts/TimeSeriesChart";
import { Async } from "../components/Async";
import { BanDialog } from "../components/BanDialog";
import { Card } from "../components/Card";
import { InfoTip } from "../components/InfoTip";
import { Skeleton } from "../components/Skeleton";
import { StatusChip } from "../components/StatusChip";
import type { StatId } from "../copy/stats";
import { fmtAgo, fmtCount, fmtDateTime } from "../lib/format";
import { SERIES } from "../theme/tokens";

export default function InstallDetailPage() {
  const { hash = "" } = useParams();
  const query = useInstall(hash);
  const client = useQueryClient();
  const [banning, setBanning] = useState(false);
  const refresh = () => {
    void client.invalidateQueries({ queryKey: ["install", hash] });
    void client.invalidateQueries({ queryKey: ["installs"] });
  };
  const ban = useMutation({
    mutationFn: (reason: string) => api.ban(hash, reason),
    onSuccess: () => {
      setBanning(false);
      refresh();
    },
  });
  const unban = useMutation({ mutationFn: () => api.unban(hash), onSuccess: refresh });

  return (
    <>
      <Link
        to="/installs"
        className="mb-4 inline-flex items-center gap-1 text-sm text-ctp-subtext0 hover:text-ctp-text"
      >
        <ArrowLeft className="size-4" aria-hidden /> Installs
      </Link>
      <Async query={query} skeleton={<Skeleton className="h-96" />}>
        {({ install: r, daily }) => (
          <div className="space-y-6">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div>
                <h1 className="flex items-center gap-3 text-xl font-semibold">
                  Install <StatusChip row={r} />
                </h1>
                <p className="mt-1 font-mono text-xs break-all text-ctp-subtext0">{r.hash}</p>
                {r.banned && r.banReason && (
                  <p className="mt-1 text-sm text-ctp-red">Banned: {r.banReason}</p>
                )}
              </div>
              {r.banned ? (
                <button
                  type="button"
                  disabled={unban.isPending}
                  onClick={() => unban.mutate()}
                  className="rounded-lg bg-ctp-surface1 px-4 py-2 text-sm hover:bg-ctp-surface2 disabled:opacity-50"
                >
                  {unban.isPending ? "Unbanning…" : "Unban"}
                </button>
              ) : (
                <button
                  type="button"
                  onClick={() => setBanning(true)}
                  className="rounded-lg bg-ctp-red/15 px-4 py-2 text-sm font-medium text-ctp-red ring-1 ring-ctp-red/40 hover:bg-ctp-red/25"
                >
                  Ban install
                </button>
              )}
            </div>

            <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
              <Fact label="First seen" statId="col.firstSeen" value={fmtDateTime(r.firstSeen)} />
              <Fact
                label="Last seen"
                statId="col.lastSeen"
                value={`${fmtAgo(r.lastSeen)} · ${fmtDateTime(r.lastSeen)}`}
              />
              <Fact
                label="App version"
                statId="col.version"
                value={r.appVersionCode?.toString() ?? "—"}
              />
              <Fact label="Device tier" statId="col.tier" value={r.deviceTier ?? "—"} />
              <Fact label="Licensing" statId="detail.licensing" value={r.licensing ?? "—"} />
              <Fact
                label="Android SDK"
                statId="detail.sdk"
                value={r.sdkVersion?.toString() ?? "—"}
              />
              <Fact label="Total calls" statId="col.callsTotal" value={fmtCount(r.callsTotal)} />
              <Fact label="Quota days" statId="col.quotaHitDays" value={fmtCount(r.quotaHitDays)} />
            </div>

            <Card title="Activity" statId="detail.activity">
              <ActivityStrip daily={daily} />
            </Card>
            <div className="grid gap-4 lg:grid-cols-2">
              <Card title="Calls per day" statId="chart.installCalls">
                <TimeSeriesChart
                  data={daily.slice(-90).map(({ day, calls, tokens }) => ({ day, calls, tokens }))}
                  kind="bar"
                  series={[{ key: "calls", label: "Calls", color: SERIES[0] }]}
                />
              </Card>
              <Card title="Tokens per day" statId="chart.installTokens">
                <TimeSeriesChart
                  data={daily.slice(-90).map(({ day, calls, tokens }) => ({ day, calls, tokens }))}
                  kind="area"
                  series={[{ key: "tokens", label: "Tokens", color: SERIES[3] }]}
                />
              </Card>
            </div>

            {banning && (
              <BanDialog
                hash={r.hash}
                pending={ban.isPending}
                error={
                  ban.error
                    ? ban.error instanceof ApiError
                      ? `Couldn't ban: ${ban.error.code}`
                      : "Couldn't reach the server."
                    : null
                }
                onClose={() => setBanning(false)}
                onConfirm={(reason) => ban.mutate(reason)}
              />
            )}
          </div>
        )}
      </Async>
    </>
  );
}

function Fact({ label, value, statId }: { label: string; value: string; statId: StatId }) {
  return (
    <div className="rounded-xl bg-ctp-surface0 p-4 ring-1 ring-ctp-surface1/40">
      <div className="flex items-center gap-1.5 text-xs text-ctp-subtext0">
        {label}
        <InfoTip id={statId} />
      </div>
      <div className="mt-1 text-sm text-ctp-text">{value}</div>
    </div>
  );
}
