import { RANGES, useRange } from "../lib/range";
import { Segmented } from "./Segmented";

export function RangePicker() {
  const [range, setRange] = useRange();
  return <Segmented label="Range" options={RANGES} value={range} onChange={setRange} />;
}
