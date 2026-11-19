// Knot — chrome shells: macOS popover (with anchor notch), detached window
// (chromeless w/ traffic lights), iOS app frame.

function ChromeActions({ isDetached = false, onDetach = () => {} }) {
  return (
    <div className="kn-chrome-actions">
      <button
        className="kn-pipdot"
        onClick={onDetach}
        title={isDetached ? "Reattach to menu bar" : "Detach to window"}
        aria-label={isDetached ? "Reattach" : "Detach"}
      >
        <Glyph name={isDetached ? "pip-enter" : "pip-exit"} size={9} weight={1.7} />
      </button>
    </div>
  );
}

function PopoverShell({ width = 440, height = 320, children, theme = "dark" }) {
  return (
    <div className="kn-popover-stage" data-theme={theme}>
      <div className="kn-popover" style={{ width, height }}>
        <div className="kn-popover__notch" aria-hidden />
        <div className="kn-popover__chrome">
          <span className="kn-popover__spacer" />
          <ChromeActions isDetached={false} />
        </div>
        <div className="kn-popover__body">{children}</div>
      </div>
    </div>
  );
}

function DetachedShell({
  width = 440, height = 320, children, theme = "dark",
  chrome = "lights", // "lights" | "handle" | "minimal"
}) {
  return (
    <div className="kn-window-stage" data-theme={theme}>
      <div className="kn-window" style={{ width, height }}>
        {chrome === "lights" && (
          <div className="kn-window__chrome">
            <div className="kn-tl">
              <span className="kn-tl__dot kn-tl__dot--close" />
              <span className="kn-tl__dot kn-tl__dot--min" />
              <span className="kn-tl__dot kn-tl__dot--max" />
            </div>
            <span className="kn-window__chrome-spacer" />
            <ChromeActions isDetached={true} />
          </div>
        )}
        {chrome === "handle" && (
          <div className="kn-window__chrome kn-window__chrome--handle">
            <div className="kn-tl kn-tl--single">
              <span className="kn-tl__dot kn-tl__dot--close" />
            </div>
            <div className="kn-handle" aria-hidden>
              <span /><span /><span />
            </div>
            <ChromeActions isDetached={true} />
          </div>
        )}
        {chrome === "minimal" && (
          <div className="kn-window__chrome kn-window__chrome--min">
            <button className="kn-tl__dot kn-tl__dot--close" title="Close" />
            <span className="kn-window__chrome-spacer" />
            <ChromeActions isDetached={true} />
          </div>
        )}
        <div className="kn-window__body" data-chrome={chrome}>{children}</div>
      </div>
    </div>
  );
}

function IOSShell({ width = 390, height = 720, children, theme = "dark", title = "Knot" }) {
  return (
    <div className="kn-ios-stage" data-theme={theme}>
      <div className="kn-ios" style={{ width, height }}>
        <div className="kn-ios__statusbar">
          <span className="kn-ios__time">9:41</span>
          <span className="kn-ios__notch" />
          <span className="kn-ios__icons">
            <svg width="16" height="11" viewBox="0 0 16 11" fill="none">
              <path d="M.5 8.5h2v2h-2zM4.5 6.5h2v4h-2zM8.5 4.5h2v6h-2zM12.5 2.5h2v8h-2z" fill="currentColor"/>
            </svg>
            <svg width="22" height="11" viewBox="0 0 22 11" fill="none">
              <rect x=".5" y=".5" width="18" height="10" rx="2.5" stroke="currentColor" opacity=".4"/>
              <rect x="2" y="2" width="13" height="7" rx="1.2" fill="currentColor"/>
            </svg>
          </span>
        </div>
        <div className="kn-ios__nav">
          <span className="kn-ios__title">{title}</span>
          <button className="kn-iconbtn kn-ios__gear" aria-label="Settings">
            <Glyph name="gear" size={17} />
          </button>
        </div>
        <div className="kn-ios__body">{children}</div>
      </div>
    </div>
  );
}

window.PopoverShell = PopoverShell;
window.DetachedShell = DetachedShell;
window.IOSShell = IOSShell;
