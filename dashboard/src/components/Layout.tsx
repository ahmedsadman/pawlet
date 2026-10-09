import { useMutation, useQueryClient } from "@tanstack/react-query";
import {
  Activity,
  Gauge,
  Layers,
  LogOut,
  Menu,
  PawPrint,
  ShieldCheck,
  Smartphone,
  X,
} from "lucide-react";
import { useEffect, useState } from "react";
import { NavLink, Outlet, useNavigate } from "react-router";
import { api } from "../api/client";

const NAV = [
  { to: "/", label: "Overview", icon: Gauge, end: true },
  { to: "/installs", label: "Installs", icon: Smartphone, end: false },
  { to: "/engagement", label: "Engagement", icon: Activity, end: false },
  { to: "/reliability", label: "Reliability", icon: ShieldCheck, end: false },
  { to: "/fleet", label: "Fleet", icon: Layers, end: false },
];

function Sidebar({ onNavigate }: { onNavigate?: () => void }) {
  const client = useQueryClient();
  const navigate = useNavigate();
  const logout = useMutation({
    mutationFn: api.logout,
    onSettled: () => {
      client.removeQueries();
      navigate("/login", { replace: true });
    },
  });
  return (
    <div className="flex h-full flex-col bg-ctp-mantle p-3">
      <div className="mb-6 flex items-center gap-2 px-2 pt-1">
        <PawPrint className="size-5 text-ctp-mauve" aria-hidden />
        <span className="font-semibold text-ctp-text">Pawlet</span>
        <span className="text-xs text-ctp-subtext0">admin</span>
      </div>
      <nav aria-label="Main" className="flex-1 space-y-1">
        {NAV.map(({ to, label, icon: Icon, end }) => (
          <NavLink
            key={to}
            to={to}
            end={end}
            onClick={onNavigate}
            className={({ isActive }) =>
              `flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition-colors ${
                isActive
                  ? "bg-ctp-surface0 text-ctp-text"
                  : "text-ctp-subtext0 hover:bg-ctp-surface0/60 hover:text-ctp-text"
              }`
            }
          >
            {({ isActive }) => (
              <>
                <Icon className={`size-4 ${isActive ? "text-ctp-mauve" : ""}`} aria-hidden />
                {label}
              </>
            )}
          </NavLink>
        ))}
      </nav>
      <button
        type="button"
        onClick={() => logout.mutate()}
        className="flex items-center gap-3 rounded-lg px-3 py-2 text-sm text-ctp-subtext0 hover:bg-ctp-surface0/60 hover:text-ctp-text"
      >
        <LogOut className="size-4" aria-hidden /> Sign out
      </button>
    </div>
  );
}

export function Layout() {
  const [open, setOpen] = useState(false);

  useEffect(() => {
    if (!open) return;
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [open]);

  return (
    <div className="min-h-dvh md:grid md:grid-cols-[14rem_1fr]">
      <aside className="sticky top-0 hidden h-dvh md:block">
        <Sidebar />
      </aside>
      <header className="sticky top-0 z-30 flex items-center gap-3 bg-ctp-mantle px-4 py-3 md:hidden">
        <button
          type="button"
          aria-label="Open menu"
          onClick={() => setOpen(true)}
          className="text-ctp-subtext1"
        >
          <Menu className="size-5" />
        </button>
        <PawPrint className="size-5 text-ctp-mauve" aria-hidden />
        <span className="font-semibold">Pawlet</span>
      </header>
      {open && (
        <div className="fixed inset-0 z-40 md:hidden">
          <div
            className="absolute inset-0 bg-ctp-crust/70"
            onClick={() => setOpen(false)}
            aria-hidden
          />
          <div className="absolute inset-y-0 left-0 w-64 shadow-2xl">
            <button
              type="button"
              aria-label="Close menu"
              onClick={() => setOpen(false)}
              className="absolute top-3 right-3 text-ctp-subtext1"
            >
              <X className="size-5" />
            </button>
            <Sidebar onNavigate={() => setOpen(false)} />
          </div>
        </div>
      )}
      <main className="mx-auto w-full max-w-7xl p-4 md:p-8">
        <Outlet />
      </main>
    </div>
  );
}
