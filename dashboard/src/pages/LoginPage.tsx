import { useMutation, useQueryClient } from "@tanstack/react-query";
import { PawPrint } from "lucide-react";
import { useId, useState } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { api, ApiError } from "../api/client";
import { safeNext } from "../auth";

function loginMessage(error: unknown): string | null {
  if (!error) return null;
  if (error instanceof ApiError) {
    if (error.status === 401) return "Wrong password.";
    if (error.status === 429) return "Too many attempts. Try again in a few minutes.";
    return "Couldn't sign in. Try again.";
  }
  return "Couldn't reach the server.";
}

export default function LoginPage() {
  const [password, setPassword] = useState("");
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const client = useQueryClient();
  const inputId = useId();
  const login = useMutation({
    mutationFn: api.login,
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: ["me"] });
      navigate(safeNext(params.get("next")), { replace: true });
    },
  });
  const message = loginMessage(login.error);

  return (
    <main className="grid min-h-dvh place-items-center bg-ctp-crust p-4">
      <form
        onSubmit={(e) => {
          e.preventDefault();
          if (password) login.mutate(password);
        }}
        className="w-full max-w-sm rounded-2xl bg-ctp-mantle p-8 shadow-2xl ring-1 ring-ctp-surface0"
      >
        <div className="mb-6 flex items-center gap-2">
          <PawPrint className="size-6 text-ctp-mauve" aria-hidden />
          <h1 className="text-lg font-semibold text-ctp-text">Pawlet admin</h1>
        </div>
        <label htmlFor={inputId} className="text-xs font-medium text-ctp-subtext1">
          Password
        </label>
        <input
          id={inputId}
          type="password"
          autoComplete="current-password"
          autoFocus
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          className="mt-1 w-full rounded-lg bg-ctp-surface0 px-3 py-2 text-sm text-ctp-text ring-1 ring-ctp-surface1 focus:ring-2 focus:ring-ctp-mauve focus:outline-none"
        />
        {message && (
          <p role="alert" className="mt-2 text-sm text-ctp-red">
            {message}
          </p>
        )}
        <button
          type="submit"
          disabled={!password || login.isPending}
          className="mt-5 w-full rounded-lg bg-ctp-mauve py-2 text-sm font-semibold text-ctp-crust transition-opacity hover:opacity-90 disabled:opacity-50"
        >
          {login.isPending ? "Signing in…" : "Sign in"}
        </button>
      </form>
    </main>
  );
}
