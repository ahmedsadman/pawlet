import type { KeyCount } from "../api/types";
import { Card } from "../components/Card";
import { BarList } from "./BarList";

const LABEL_FOR: Record<string, string> = {
  on: "LLM on",
  off: "Turned off",
  byok: "Own key",
  none: "No LLM",
  unknown: "Unknown",
};

export function LlmGroupsCard({ items }: { items: KeyCount[] }) {
  const allZero = items.every((i) => i.count === 0);
  return (
    <Card title="LLM setting" statId="chart.llmGroups">
      <BarList items={allZero ? [] : items} labelFor={(k) => LABEL_FOR[k] || k} />
    </Card>
  );
}
