export function Skeleton({ className = "h-40" }: { className?: string }) {
  return <div className={`animate-pulse rounded-xl bg-ctp-surface0/70 ${className}`} aria-hidden />;
}
