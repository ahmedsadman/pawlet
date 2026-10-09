export function Segmented<T extends string>({
  label,
  options,
  value,
  onChange,
}: {
  label: string;
  options: { key: T; label: string }[];
  value: T;
  onChange: (v: T) => void;
}) {
  return (
    <div
      role="radiogroup"
      aria-label={label}
      className="inline-flex rounded-lg bg-ctp-mantle p-1 ring-1 ring-ctp-surface0"
    >
      {options.map((o) => (
        <button
          key={o.key}
          type="button"
          role="radio"
          aria-checked={value === o.key}
          onClick={() => onChange(o.key)}
          className={`rounded-md px-3 py-1 text-xs font-medium transition-colors ${
            value === o.key
              ? "bg-ctp-surface1 text-ctp-text shadow"
              : "text-ctp-subtext0 hover:text-ctp-text"
          }`}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}
