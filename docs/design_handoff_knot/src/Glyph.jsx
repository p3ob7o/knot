// Tiny SF-Symbol-style glyph set rendered as inline SVG so designs work offline.
// Each glyph: 16×16 viewBox, stroke=currentColor, sized by `size` prop.

function Glyph({ name, size = 16, weight = 1.6, ...rest }) {
  const common = {
    width: size, height: size, viewBox: "0 0 16 16", fill: "none",
    stroke: "currentColor", strokeWidth: weight,
    strokeLinecap: "round", strokeLinejoin: "round", ...rest,
  };

  switch (name) {
    case "gear":
      return (
        <svg {...common}>
          <path d="M9.4 1.7l.35 1.55a5.5 5.5 0 0 1 1.46.6l1.36-.84 1.42 1.42-.84 1.36c.27.45.47.94.6 1.46l1.55.35v2l-1.55.35a5.5 5.5 0 0 1-.6 1.46l.84 1.36-1.42 1.42-1.36-.84a5.5 5.5 0 0 1-1.46.6l-.35 1.55h-2l-.35-1.55a5.5 5.5 0 0 1-1.46-.6l-1.36.84-1.42-1.42.84-1.36a5.5 5.5 0 0 1-.6-1.46L1.5 9v-2l1.55-.35c.13-.52.33-1.01.6-1.46l-.84-1.36 1.42-1.42 1.36.84a5.5 5.5 0 0 1 1.46-.6l.35-1.55h2z" />
          <circle cx="8" cy="8" r="2.2" />
        </svg>
      );
    case "pip-exit":
      return (
        <svg {...common}>
          <rect x="1.8" y="3" width="9" height="7" rx="1.4" />
          <rect x="6.5" y="6.5" width="7.7" height="6" rx="1.2" fill="currentColor" fillOpacity="0.18" />
        </svg>
      );
    case "pip-enter":
      return (
        <svg {...common}>
          <rect x="2.2" y="3.5" width="11.6" height="9" rx="1.4" />
          <rect x="2.2" y="3.5" width="6" height="5" rx="1" fill="currentColor" fillOpacity="0.18" />
        </svg>
      );
    case "arrow-up":
      // Filled circle send, with up-arrow knockout
      return (
        <svg width={size} height={size} viewBox="0 0 16 16" {...rest}>
          <circle cx="8" cy="8" r="7" fill="currentColor" />
          <path d="M8 4.4 L 8 11.6 M 5 7.4 L 8 4.4 L 11 7.4"
                stroke="var(--send-fg, #1d1d1f)" strokeWidth="1.6"
                strokeLinecap="round" strokeLinejoin="round" fill="none" />
        </svg>
      );
    case "folder":
      return (
        <svg {...common}>
          <path d="M1.5 4.4c0-.7.5-1.2 1.2-1.2h3l1.4 1.4h6.2c.7 0 1.2.5 1.2 1.2v6.4c0 .7-.5 1.2-1.2 1.2H2.7c-.7 0-1.2-.5-1.2-1.2V4.4Z" />
        </svg>
      );
    case "check":
      return (
        <svg {...common}>
          <circle cx="8" cy="8" r="6.6" fill="currentColor" stroke="none" />
          <path d="M5 8.2 L 7.2 10.4 L 11 6.4" stroke="var(--ok-fg, #fff)" strokeWidth="1.7" />
        </svg>
      );
    case "warning":
      return (
        <svg {...common}>
          <path d="M8 1.6 L 14.6 13.2 H 1.4 Z" fill="currentColor" stroke="none" />
          <path d="M8 6 V 9.6 M 8 11.4 V 11.6"
                stroke="var(--err-fg, #fff)" strokeWidth="1.7" />
        </svg>
      );
    case "calendar":
      return (
        <svg {...common}>
          <rect x="1.8" y="3" width="12.4" height="11" rx="1.6" />
          <path d="M1.8 6.2h12.4M5 1.8v2.4M11 1.8v2.4" />
        </svg>
      );
    case "tray":
      return (
        <svg {...common}>
          <path d="M1.6 8.4v3.6c0 .9.7 1.6 1.6 1.6h9.6c.9 0 1.6-.7 1.6-1.6V8.4" />
          <path d="M1.6 8.4 3.4 3.2c.2-.5.6-.8 1.1-.8h6.8c.5 0 .9.3 1.1.8l1.8 5.2" />
          <path d="M1.6 8.4h3.6l1 1.8h3.6l1-1.8h3.6" />
        </svg>
      );
    case "x":
      return (
        <svg {...common}>
          <path d="M3.5 3.5 L 12.5 12.5 M 12.5 3.5 L 3.5 12.5" />
        </svg>
      );
    case "chevron-down":
      return (
        <svg {...common}>
          <path d="M3.5 6 L 8 10.5 L 12.5 6" />
        </svg>
      );
    case "command":
      return (
        <svg {...common}>
          <path d="M5.5 5.5h5v5h-5z" />
          <circle cx="3.7" cy="3.7" r="1.7" />
          <circle cx="12.3" cy="3.7" r="1.7" />
          <circle cx="3.7" cy="12.3" r="1.7" />
          <circle cx="12.3" cy="12.3" r="1.7" />
        </svg>
      );
    case "return":
      return (
        <svg {...common}>
          <path d="M13 4 V 7.5 a 2 2 0 0 1 -2 2 H 3 M 6 6.5 L 3 9.5 L 6 12.5" />
        </svg>
      );
    case "spinner":
      return (
        <svg width={size} height={size} viewBox="0 0 16 16" {...rest}>
          <circle cx="8" cy="8" r="6" stroke="currentColor" strokeOpacity="0.2" strokeWidth="1.8" fill="none" />
          <path d="M8 2 a 6 6 0 0 1 6 6" stroke="currentColor" strokeWidth="1.8"
                strokeLinecap="round" fill="none">
            <animateTransform attributeName="transform" type="rotate"
                              from="0 8 8" to="360 8 8" dur="0.9s" repeatCount="indefinite" />
          </path>
        </svg>
      );
    default:
      return null;
  }
}

window.Glyph = Glyph;
