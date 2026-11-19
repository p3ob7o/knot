// Knot — Brand mark showcase artboard

function MarkShowcase({ theme = "dark" }) {
  return (
    <div data-theme={theme} style={{
      padding: 40,
      background: "var(--bg-window)",
      borderRadius: 12,
      display: "grid",
      gridTemplateColumns: "1.2fr 1fr 1fr",
      gap: 32,
      width: 1040,
      alignItems: "center",
    }}>
      {/* Hero: large mark on plain background */}
      <div style={{
        display: "flex", alignItems: "center", justifyContent: "center",
        height: 220,
        borderRadius: 10,
        background: "var(--bg-3)",
      }}>
        <div style={{ color: "var(--fg)" }}>
          <KnotMark size={140} />
        </div>
      </div>

      {/* Mark + wordmark lockup */}
      <div style={{
        display: "flex", alignItems: "center", justifyContent: "center",
        height: 220,
        borderRadius: 10,
        background: "var(--bg-3)",
        gap: 14,
      }}>
        <div style={{ color: "var(--fg)" }}>
          <KnotMark size={56} />
        </div>
        <span className="serif" style={{
          font: "700 56px/1 var(--font-display)",
          letterSpacing: "-0.02em",
          color: "var(--fg)",
        }}>Knot</span>
      </div>

      {/* Size ladder */}
      <div style={{
        display: "flex", flexDirection: "column", justifyContent: "center",
        height: 220,
        borderRadius: 10,
        background: "var(--bg-3)",
        padding: "0 28px",
        gap: 18,
      }}>
        {[
          { px: 64, label: "App icon" },
          { px: 32, label: "Window" },
          { px: 20, label: "Title" },
          { px: 16, label: "Status bar" },
        ].map(({ px, label }) => (
          <div key={px} style={{
            display: "flex", alignItems: "center", gap: 14,
            color: "var(--fg-2)",
            font: "11px var(--font-ui)",
          }}>
            <div style={{
              width: 64, display: "flex", justifyContent: "center",
              color: "var(--fg)",
            }}>
              <KnotMark size={px} />
            </div>
            <span style={{ flex: 1 }}>{label}</span>
            <span style={{ color: "var(--fg-3)" }}>{px}px</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// macOS menu bar simulation showing the status icon
function MenuBarSim({ theme = "dark", popoverOpen = false }) {
  return (
    <div style={{
      width: 1040, height: 80,
      background: "linear-gradient(180deg, #6b8c9c 0%, #4a6478 100%)",
      borderRadius: 10,
      position: "relative",
      overflow: "hidden",
    }}>
      <div className="kn-menubar">
        <span className="kn-menubar__apple" />
        <span style={{ fontWeight: 600 }}>Obsidian</span>
        <span style={{ opacity: 0.85 }}>File</span>
        <span style={{ opacity: 0.85 }}>Edit</span>
        <span style={{ opacity: 0.85 }}>View</span>
        <span className="kn-menubar__spacer" />
        <span className={`kn-menubar__icon ${popoverOpen ? "is-active" : ""}`} style={{ color: "#fff" }}>
          <KnotMark size={14} />
        </span>
        <span style={{ opacity: 0.85 }}>100%</span>
        <span style={{ opacity: 0.85 }}>Sat 25 Apr</span>
        <span style={{ opacity: 0.85 }}>9:41</span>
      </div>
    </div>
  );
}

window.MarkShowcase = MarkShowcase;
window.MenuBarSim = MenuBarSim;
