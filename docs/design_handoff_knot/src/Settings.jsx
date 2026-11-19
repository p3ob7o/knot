// Knot — Settings window (macOS).

function SettingRow({ label, children }) {
  return (
    <div className="kn-row-s">
      <div className="kn-row-s__label">{label}</div>
      <div className="kn-row-s__value">{children}</div>
    </div>
  );
}

function Toggle({ on, onChange }) {
  return (
    <div className={`kn-toggle ${on ? "is-on" : ""}`} onClick={() => onChange(!on)} role="switch" aria-checked={on} />
  );
}

function Settings({ theme = "dark" }) {
  const [forceMulti, setForceMulti] = React.useState(true);

  return (
    <div className="kn-settings-stage" data-theme={theme}>
      <div className="kn-settings">
        <div className="kn-settings__chrome">
          <div className="kn-tl">
            <span className="kn-tl__dot kn-tl__dot--close" />
            <span className="kn-tl__dot kn-tl__dot--min" />
            <span className="kn-tl__dot kn-tl__dot--max" />
          </div>
          <div className="kn-settings__title">Knot Settings</div>
          <div />
        </div>

        <div className="kn-settings__body">
          {/* Vault */}
          <div>
            <div className="kn-section__head">Vault</div>
            <div className="kn-card">
              <SettingRow label={(<span style={{display:"inline-flex", gap:6, alignItems:"center"}}><Glyph name="folder" size={13}/> Gake</span>)}>
                <button className="kn-btn">Change…</button>
              </SettingRow>
              <SettingRow label="">
                <button className="kn-btn kn-btn--destructive" style={{marginLeft:"auto"}}>Disconnect vault</button>
              </SettingRow>
            </div>
          </div>

          {/* Toggle Knot */}
          <div>
            <div className="kn-section__head">Toggle Knot</div>
            <div className="kn-card" style={{ padding: 10 }}>
              <div className="kn-hotkey">
                <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>⌘</kbd>
                <kbd style={{minWidth:28}}>K</kbd>
              </div>
              <div className="kn-help">
                Click the field, then press any single character with any combination of ⌃ ⌥ ⇧ ⌘. Backspace clears; Esc cancels.
              </div>
            </div>
          </div>

          {/* Folders */}
          <div>
            <div className="kn-section__head">Folders</div>
            <div className="kn-card">
              <SettingRow label="Daily folder">
                <input className="kn-input mono" defaultValue="1_Diary" />
              </SettingRow>
              <SettingRow label="Inbox folder">
                <input className="kn-input mono" defaultValue="0_Inbox/Quick Notes" />
              </SettingRow>
            </div>
          </div>

          {/* Daily note */}
          <div>
            <div className="kn-section__head">Daily note</div>
            <div className="kn-card">
              <SettingRow label="Filename pattern">
                <input className="kn-input mono" defaultValue="YYYY/MM/YYYY-MM-DD dddd" />
              </SettingRow>
              <SettingRow label="Heading">
                <input className="kn-input mono" defaultValue="## Quick notes" />
              </SettingRow>
              <SettingRow label="Bullet format">
                <input className="kn-input mono" defaultValue="- {{HH:mm}} {{content}}" />
              </SettingRow>
            </div>
            <div className="kn-help">
              Filename and bullet patterns use Moment.js display format — same conventions as Obsidian's Daily Notes. Slashes create subfolders. <a href="#" className="kn-link">Open the format reference →</a>
            </div>
          </div>

          {/* Inbox */}
          <div>
            <div className="kn-section__head">Inbox</div>
            <div className="kn-card">
              <SettingRow label="Filename">
                <input className="kn-input mono" defaultValue="YYYY-MM-DD HHmm" />
              </SettingRow>
            </div>
            <div className="kn-help">
              Slashes create subfolders. Wrap literal text in [brackets] — e.g. [Notes]/YYYY-MM-DD.
            </div>
          </div>

          {/* Routing */}
          <div>
            <div className="kn-section__head">Routing</div>
            <div className="kn-card">
              <SettingRow label="Max characters for daily">
                <input className="kn-input mono" defaultValue="280" style={{maxWidth:80}} />
              </SettingRow>
              <SettingRow label="Force inbox when multiple lines">
                <Toggle on={forceMulti} onChange={setForceMulti} />
              </SettingRow>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

window.Settings = Settings;
