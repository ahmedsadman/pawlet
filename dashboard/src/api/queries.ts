import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { api } from "./client";
import type { ActiveMode, InstallsQuery, RangeKey } from "./types";

export const useOverview = (range: RangeKey) =>
  useQuery({ queryKey: ["overview", range], queryFn: () => api.overview(range) });

export const useInstalls = (q: InstallsQuery) =>
  useQuery({
    queryKey: ["installs", q],
    queryFn: () => api.installs(q),
    placeholderData: keepPreviousData,
  });

export const useInstall = (hash: string) =>
  useQuery({ queryKey: ["install", hash], queryFn: () => api.install(hash) });

export const useEngagement = (range: RangeKey, active: ActiveMode) =>
  useQuery({
    queryKey: ["engagement", range, active],
    queryFn: () => api.engagement(range, active),
  });

export const useReliability = (range: RangeKey) =>
  useQuery({ queryKey: ["reliability", range], queryFn: () => api.reliability(range) });

export const useFleet = () => useQuery({ queryKey: ["fleet"], queryFn: api.fleet });
