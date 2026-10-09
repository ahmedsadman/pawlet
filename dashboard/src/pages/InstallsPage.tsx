import { ArrowDown, ArrowUp, ChevronLeft, ChevronRight, Search } from "lucide-react";
import { Link, useNavigate, useSearchParams } from "react-router";
import { useInstalls } from "../api/queries";
import type { InstallRow } from "../api/types";
import { Async } from "../components/Async";
import { InfoTip } from "../components/InfoTip";
import { MessagesCell } from "../components/MessagesCell";
import { PageHeader } from "../components/PageHeader";
import { Segmented } from "../components/Segmented";
import { Skeleton } from "../components/Skeleton";
import { StatusChip } from "../components/StatusChip";
import type { StatId } from "../copy/stats";
import { fmtAgo, fmtCount, fmtDateTime, shortHash } from "../lib/format";

const STATUSES = [
  { key: "all", label: "All" },
  { key: "active", label: "Active" },
  { key: "dormant", label: "Dormant" },
  { key: "banned", label: "Banned" },
] as const;
type Status = (typeof STATUSES)[number]["key"];

interface Column {
  key: string;
  label: string;
  statId: StatId;
  sort?: string;
  align?: "right";
  cell: (r: InstallRow) => React.ReactNode;
}

const COLUMNS: Column[] = [
  {
    key: "hash",
    label: "Install",
    statId: "col.hash",
    cell: (r) => (
      <Link
        to={`/installs/${r.hash}`}
        className="font-mono text-ctp-text rounded"
        onClick={(e) => e.stopPropagation()}
      >
        {shortHash(r.hash)}
      </Link>
    ),
  },
  {
    key: "firstSeen",
    label: "First seen",
    statId: "col.firstSeen",
    sort: "firstSeen",
    cell: (r) => <span title={fmtDateTime(r.firstSeen)}>{fmtAgo(r.firstSeen)}</span>,
  },
  {
    key: "lastSeen",
    label: "Last seen",
    statId: "col.lastSeen",
    sort: "lastSeen",
    cell: (r) => <span title={fmtDateTime(r.lastSeen)}>{fmtAgo(r.lastSeen)}</span>,
  },
  {
    key: "version",
    label: "Version",
    statId: "col.version",
    sort: "appVersionCode",
    cell: (r) => r.appVersionCode ?? "—",
  },
  { key: "tier", label: "Tier", statId: "col.tier", cell: (r) => r.deviceTier ?? "—" },
  {
    key: "today",
    label: "Today",
    statId: "col.messagesToday",
    sort: "messagesToday",
    align: "right",
    cell: (r) => (
      <MessagesCell messages={r.messagesToday} calls={r.callsToday} hasStats={r.hasModelStats} />
    ),
  },
  {
    key: "week",
    label: "7 days",
    statId: "col.messages7d",
    sort: "messages7d",
    align: "right",
    cell: (r) => (
      <MessagesCell messages={r.messages7d} calls={r.calls7d} hasStats={r.hasModelStats} />
    ),
  },
  {
    key: "total",
    label: "Total",
    statId: "col.messagesTotal",
    sort: "messagesTotal",
    align: "right",
    cell: (r) => (
      <MessagesCell messages={r.messagesTotal} calls={r.callsTotal} hasStats={r.hasModelStats} />
    ),
  },
  {
    key: "tokensTotal",
    label: "Tokens",
    statId: "col.tokensTotal",
    sort: "tokensTotal",
    align: "right",
    cell: (r) => fmtCount(r.tokensTotal),
  },
  {
    key: "quota",
    label: "Quota days",
    statId: "col.quotaHitDays",
    sort: "quotaHitDays",
    align: "right",
    cell: (r) => r.quotaHitDays || "—",
  },
  { key: "status", label: "Status", statId: "col.status", cell: (r) => <StatusChip row={r} /> },
];

export default function InstallsPage() {
  const [params, setParams] = useSearchParams();
  const navigate = useNavigate();
  const status = (STATUSES.find((s) => s.key === params.get("status"))?.key ?? "all") as Status;
  const validSorts = COLUMNS.filter((c) => c.sort).map((c) => c.sort!);
  const rawSort = params.get("sort");
  const sort = rawSort && validSorts.includes(rawSort) ? rawSort : "lastSeen";
  const order = params.get("order") === "asc" ? "asc" : "desc";
  const q = params.get("q") ?? "";
  const page = Math.max(1, Number(params.get("page")) || 1);
  const query = useInstalls({ status, sort, order, q, page });

  const update = (changes: Record<string, string | null>) =>
    setParams(
      (prev) => {
        const next = new URLSearchParams(prev);
        for (const [k, v] of Object.entries(changes)) {
          if (v === null || v === "") next.delete(k);
          else next.set(k, v);
        }
        if (!("page" in changes)) next.delete("page");
        return next;
      },
      { replace: true },
    );

  const toggleSort = (key: string) =>
    update(
      sort === key ? { order: order === "asc" ? "desc" : "asc" } : { sort: key, order: "desc" },
    );

  return (
    <>
      <PageHeader title="Installs">
        <label className="relative">
          <span className="sr-only">Search by install hash</span>
          <Search
            className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-ctp-overlay1"
            aria-hidden
          />
          <input
            value={q}
            onChange={(e) => update({ q: e.target.value.toLowerCase().replace(/[^0-9a-f]/g, "") })}
            placeholder="Hash prefix"
            className="w-40 rounded-lg bg-ctp-mantle py-1.5 pr-3 pl-8 font-mono text-xs text-ctp-text ring-1 ring-ctp-surface0 focus:ring-ctp-mauve focus:outline-none"
          />
        </label>
        <Segmented
          label="Status"
          options={[...STATUSES]}
          value={status}
          onChange={(s) => update({ status: s === "all" ? null : s })}
        />
      </PageHeader>
      <Async query={query} skeleton={<Skeleton className="h-96" />}>
        {(d) => {
          const pages = Math.max(1, Math.ceil(d.total / d.pageSize));
          return (
            <div className="rounded-xl bg-ctp-surface0 ring-1 ring-ctp-surface1/40">
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-ctp-surface1 text-xs text-ctp-subtext0">
                      {COLUMNS.map((c) => (
                        <th
                          key={c.key}
                          scope="col"
                          className={`px-3 py-2.5 font-medium whitespace-nowrap ${c.align === "right" ? "text-right" : "text-left"}`}
                          aria-sort={
                            c.sort && sort === c.sort
                              ? order === "asc"
                                ? "ascending"
                                : "descending"
                              : undefined
                          }
                        >
                          <span
                            className={`inline-flex items-center gap-1 ${c.align === "right" ? "flex-row-reverse" : ""}`}
                          >
                            {c.sort ? (
                              <button
                                type="button"
                                onClick={() => toggleSort(c.sort!)}
                                className="inline-flex items-center gap-1 hover:text-ctp-text"
                              >
                                {c.label}
                                {sort === c.sort &&
                                  (order === "asc" ? (
                                    <ArrowUp className="size-3" aria-hidden />
                                  ) : (
                                    <ArrowDown className="size-3" aria-hidden />
                                  ))}
                              </button>
                            ) : (
                              c.label
                            )}
                            <InfoTip id={c.statId} />
                          </span>
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {d.rows.map((r) => (
                      <tr
                        key={r.hash}
                        onClick={() => navigate(`/installs/${r.hash}`)}
                        className="cursor-pointer border-b border-ctp-surface1/50 text-ctp-subtext1 last:border-0 hover:bg-ctp-surface1/30"
                      >
                        {COLUMNS.map((c) => (
                          <td
                            key={c.key}
                            className={`tabular px-3 py-2 whitespace-nowrap ${c.align === "right" ? "text-right" : ""}`}
                          >
                            {c.cell(r)}
                          </td>
                        ))}
                      </tr>
                    ))}
                    {d.rows.length === 0 && (
                      <tr>
                        <td
                          colSpan={COLUMNS.length}
                          className="px-3 py-10 text-center text-ctp-subtext0"
                        >
                          No installs match.
                        </td>
                      </tr>
                    )}
                  </tbody>
                </table>
              </div>
              <div className="flex items-center justify-between px-3 py-2.5 text-xs text-ctp-subtext0">
                <span>
                  {fmtCount(d.total)} installs · page {d.page} of {pages}
                </span>
                <span className="flex gap-1">
                  <button
                    type="button"
                    aria-label="Previous page"
                    disabled={d.page <= 1}
                    onClick={() => update({ page: String(d.page - 1) })}
                    className="rounded p-1 hover:bg-ctp-surface1 disabled:opacity-30"
                  >
                    <ChevronLeft className="size-4" />
                  </button>
                  <button
                    type="button"
                    aria-label="Next page"
                    disabled={d.page >= pages}
                    onClick={() => update({ page: String(d.page + 1) })}
                    className="rounded p-1 hover:bg-ctp-surface1 disabled:opacity-30"
                  >
                    <ChevronRight className="size-4" />
                  </button>
                </span>
              </div>
            </div>
          );
        }}
      </Async>
    </>
  );
}
