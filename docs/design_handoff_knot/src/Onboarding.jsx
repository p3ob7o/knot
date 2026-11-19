// Knot — onboarding (shared shape, two surfaces)

function Onboarding({ surface = "popover", onPick = () => {}, error = "" }) {
  return (
    <div className="kn-onb">
      <div className="kn-hero">
        <div className="kn-hero__name">Knot</div>
        <div className="kn-onb__sub">Quick capture into your Obsidian vault.</div>
      </div>

      <ul className="kn-onb__list">
        <li>Pick your vault folder once.</li>
        <li>Short notes append to today's daily file.</li>
        <li>Longer notes go to your inbox.</li>
        <li>Local-only — no servers, no accounts.</li>
      </ul>

      <div className="kn-onb__cta" style={{ margin: "12px 0px 0px" }}>
        {error &&
        <div style={{ color: "var(--err)", font: "12px var(--font-ui)" }}>{error}</div>
        }
        <button className="kn-onb__btn" onClick={onPick}>
          <Glyph name="folder" size={14} />
          Pick vault folder…
        </button>
        <div className="kn-onb__tip">Right-click the menu bar icon for settings.</div>
      </div>
    </div>);

}

window.Onboarding = Onboarding;