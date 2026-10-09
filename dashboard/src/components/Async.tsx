import type { UseQueryResult } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { ErrorCard } from "./ErrorCard";
import { Skeleton } from "./Skeleton";

/** Renders a query's loading, error and data states. */
export function Async<T>({
  query,
  children,
  skeleton = <Skeleton />,
}: {
  query: UseQueryResult<T>;
  children: (data: T) => ReactNode;
  skeleton?: ReactNode;
}) {
  if (query.isPending) return <>{skeleton}</>;
  if (query.isError) return <ErrorCard error={query.error} onRetry={() => void query.refetch()} />;
  return <>{children(query.data)}</>;
}
