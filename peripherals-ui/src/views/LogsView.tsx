import { useEffect, useMemo, useState } from "react";

import { Card } from "../components";
import { useNixOSControl } from "../store";
import LogViewer from "./LogViewer";

export default function LogsView() {
  const { services, loadServices } = useNixOSControl();
  const [unit, setUnit] = useState("");

  useEffect(() => {
    if (services.length === 0) {
      void loadServices();
    }
  }, [services.length, loadServices]);

  const units = useMemo(
    () =>
      [...services]
        .map((service) => service.unit)
        .sort((left, right) => left.localeCompare(right)),
    [services],
  );

  return (
    <div className="view-stack">
      <div className="toolbar-row">
        <label className="inline-field">
          Source
          <select
            className="select"
            value={unit}
            onChange={(event) => setUnit(event.target.value)}
          >
            <option value="">System journal</option>
            {units.map((value) => (
              <option value={value} key={value}>
                {value}
              </option>
            ))}
          </select>
        </label>
        <span className="muted">
          Parsed journal with severity, search, filters and expandable metadata.
        </span>
      </div>

      <Card
        title={unit ? `${unit} journal` : "System journal"}
        subtitle="Structured entries from journalctl JSON"
      >
        <LogViewer unit={unit || null} />
      </Card>
    </div>
  );
}