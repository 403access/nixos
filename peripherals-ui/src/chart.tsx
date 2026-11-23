export interface ChartSeries {
  label: string;
  color: string;
  values: number[];
}

interface LineChartProps {
  series: ChartSeries[];
  labels: string[];
  min?: number;
  max?: number;
  height?: number;
  formatValue?: (value: number) => string;
  ariaLabel: string;
}

export function LineChart({
  series,
  labels,
  min,
  max,
  height = 180,
  formatValue = (value) => String(value),
  ariaLabel,
}: LineChartProps) {
  const width = 420;
  const padding = { top: 12, right: 12, bottom: 26, left: 52 };
  const plotWidth = width - padding.left - padding.right;
  const plotHeight = height - padding.top - padding.bottom;

  const values = series
    .flatMap((item) => item.values)
    .filter((value) => Number.isFinite(value));
  let low = min ?? (values.length > 0 ? Math.min(...values) : 0);
  let high = max ?? (values.length > 0 ? Math.max(...values) : 1);
  if (!Number.isFinite(low)) {
    low = 0;
  }
  if (!Number.isFinite(high)) {
    high = low + 1;
  }
  if (high <= low) {
    high = low + 1;
  }

  const count = Math.max(
    labels.length,
    ...series.map((item) => item.values.length),
    1,
  );
  const x = (index: number) =>
    padding.left +
    (count <= 1 ? plotWidth / 2 : (index / (count - 1)) * plotWidth);
  const y = (value: number) =>
    padding.top + plotHeight - ((value - low) / (high - low)) * plotHeight;

  const ticks = [low, low + (high - low) / 2, high];
  const xTicks =
    count <= 1
      ? [0]
      : [0, Math.floor((count - 1) / 2), count - 1];
  const timeLabel = (index: number) => {
    const value = labels[index];
    if (!value) {
      return "";
    }
    const date = new Date(value);
    return Number.isNaN(date.getTime())
      ? value
      : date.toLocaleTimeString([], {
          hour: "2-digit",
          minute: "2-digit",
        });
  };

  return (
    <div className="chart">
      <svg
        className="chart-svg"
        viewBox={`0 0 ${width} ${height}`}
        role="img"
        aria-label={ariaLabel}
      >
        {ticks.map((tick) => (
          <g key={`tick-${tick}`}>
            <line
              className="chart-grid"
              x1={padding.left}
              x2={width - padding.right}
              y1={y(tick)}
              y2={y(tick)}
            />
            <text
              className="chart-axis"
              x={padding.left - 8}
              y={y(tick)}
              textAnchor="end"
              dominantBaseline="middle"
            >
              {formatValue(tick)}
            </text>
          </g>
        ))}

        {xTicks.map((index) => (
          <text
            className="chart-axis"
            key={`x-${index}`}
            x={x(index)}
            y={height - 6}
            textAnchor={
              index === 0 ? "start" : index === count - 1 ? "end" : "middle"
            }
          >
            {timeLabel(index)}
          </text>
        ))}

        {series.map((item) => {
          const points = item.values
            .map((value, index) => `${x(index)},${y(value)}`)
            .join(" ");
          const lastValue =
            item.values.length > 0
              ? item.values[item.values.length - 1]
              : null;
          return (
            <g key={item.label}>
              <polyline
                points={points}
                fill="none"
                stroke={item.color}
                strokeWidth={2}
                strokeLinejoin="round"
                strokeLinecap="round"
                vectorEffect="non-scaling-stroke"
              />
              {lastValue !== null ? (
                <circle
                  cx={x(item.values.length - 1)}
                  cy={y(lastValue)}
                  r={3}
                  fill={item.color}
                />
              ) : null}
            </g>
          );
        })}
      </svg>

      <div className="chart-legend">
        {series.map((item) => {
          const last = item.values.length
            ? item.values[item.values.length - 1]
            : null;
          return (
            <span className="chart-legend-item" key={item.label}>
              <span
                className="chart-swatch"
                style={{ background: item.color }}
                aria-hidden="true"
              />
              {item.label}
              {last !== null ? <strong>{formatValue(last)}</strong> : null}
            </span>
          );
        })}
      </div>
    </div>
  );
}