// Knot — the shared Editor view. Identical body on macOS popover, detached
// window, and iOS. Only the surrounding chrome differs.

const { useState, useRef, useEffect } = React;

// Auto-routing rule from the brief: > 280 chars OR multi-line → Inbox.
function autoMode(text, forceMultilineInbox = true) {
  if (!text) return "today";
  if (text.length > 280) return "inbox";
  if (forceMultilineInbox && /\n/.test(text)) return "inbox";
  return "today";
}

function ModeToggle({ mode, onChange, variant = "segmented", auto = false }) {
  // The Today / Inbox switcher. Several visual variants explored below.
  if (variant === "segmented") {
    return (
      <div className="kn-seg" role="tablist" aria-label="Destination">
        <div className="kn-seg__thumb" data-side={mode} />
        <button
          role="tab"
          aria-selected={mode === "today"}
          className={`kn-seg__btn ${mode === "today" ? "is-active" : ""}`}
          onClick={() => onChange("today")}
        >
          Today
        </button>
        <button
          role="tab"
          aria-selected={mode === "inbox"}
          className={`kn-seg__btn ${mode === "inbox" ? "is-active" : ""}`}
          onClick={() => onChange("inbox")}
        >
          Inbox
        </button>
      </div>
    );
  }

  if (variant === "icons") {
    return (
      <div className="kn-iconseg" role="tablist" aria-label="Destination">
        <button
          role="tab"
          aria-selected={mode === "today"}
          title="Today — append to today's daily note"
          className={`kn-iconseg__btn ${mode === "today" ? "is-active" : ""}`}
          onClick={() => onChange("today")}
        >
          <Glyph name="calendar" size={14} />
          <span>Today</span>
        </button>
        <button
          role="tab"
          aria-selected={mode === "inbox"}
          title="Inbox — write a new file"
          className={`kn-iconseg__btn ${mode === "inbox" ? "is-active" : ""}`}
          onClick={() => onChange("inbox")}
        >
          <Glyph name="tray" size={14} />
          <span>Inbox</span>
        </button>
      </div>
    );
  }

  if (variant === "pill") {
    // Single switch — left=today, right=inbox. Read like a destination indicator.
    return (
      <button
        className="kn-pill"
        data-mode={mode}
        onClick={() => onChange(mode === "today" ? "inbox" : "today")}
        title="Click to flip destination"
      >
        <span className="kn-pill__icon">
          <Glyph name={mode === "today" ? "calendar" : "tray"} size={14} />
        </span>
        <span className="kn-pill__label">
          {mode === "today" ? "Today" : "Inbox"}
        </span>
        {auto && <span className="kn-pill__auto">auto</span>}
      </button>
    );
  }

  return null;
}

function StatusPill({ status, message }) {
  if (status === "idle") return null;
  if (status === "sending") {
    return (
      <span className="kn-status kn-status--sending">
        <Glyph name="spinner" size={14} />
      </span>
    );
  }
  if (status === "sent") {
    return (
      <span className="kn-status kn-status--sent" style={{ "--ok-fg": "#fff" }}>
        <Glyph name="check" size={16} style={{ color: "var(--ok)" }} />
        <span>Saved</span>
      </span>
    );
  }
  if (status === "error") {
    return (
      <span className="kn-status kn-status--error" title={message}>
        <Glyph name="warning" size={14} style={{ color: "var(--err)", "--err-fg": "#fff" }} />
        <span>{message || "Couldn't write"}</span>
      </span>
    );
  }
  return null;
}

function SendButton({ disabled, onClick, sentFlash }) {
  return (
    <button
      className={`kn-send ${disabled ? "is-disabled" : ""} ${sentFlash ? "is-sent" : ""}`}
      onClick={onClick}
      disabled={disabled}
      aria-label="Send (⌘↩)"
      title="Send · ⌘↩"
    >
      <Glyph name="arrow-up" size={26} style={{ "--send-fg": "var(--bg-window)" }} />
    </button>
  );
}

function Editor({
  // visual variants
  mode_toggle = "segmented",        // "segmented" | "icons" | "pill"
  send_feedback = "check",           // "check" | "ribbon" | "thread"
  empty_voice = "question",         // "question" | "minimal" | "verb" | "noun"
  routing_anim = "subtle",          // "subtle" | "pulse" | "silent"
  // initial state seeds for storytelling
  initialText = "",
  initialStatus = "idle",
  initialErrorMsg = "",
  // surface info
  surface = "popover",              // "popover" | "window" | "ios"
  onOpenSettings = () => {},
  onDetach = () => {},
  isDetached = false,
}) {
  const [text, setText] = useState(initialText);
  const [overrideMode, setOverrideMode] = useState(null);
  const [status, setStatus] = useState(initialStatus);
  const [errorMsg] = useState(initialErrorMsg);
  const [sentFlash, setSentFlash] = useState(false);
  const [routeFlash, setRouteFlash] = useState(false);
  const taRef = useRef(null);

  const computedAuto = autoMode(text);
  const mode = overrideMode || computedAuto;
  const isAuto = !overrideMode;

  // detect a routing flip (today→inbox or back) for the visual ping
  const lastAuto = useRef(computedAuto);
  useEffect(() => {
    if (computedAuto !== lastAuto.current) {
      lastAuto.current = computedAuto;
      if (!overrideMode && routing_anim !== "silent") {
        setRouteFlash(true);
        const t = setTimeout(() => setRouteFlash(false), 600);
        return () => clearTimeout(t);
      }
    }
  }, [computedAuto, overrideMode, routing_anim]);

  function handleSend() {
    if (!text.trim()) return;
    setStatus("sending");
    setTimeout(() => {
      setStatus("sent");
      setSentFlash(true);
      setText("");
      setOverrideMode(null);
      setTimeout(() => {
        setStatus("idle");
        setSentFlash(false);
      }, 1200);
    }, 280);
  }

  function handleKey(e) {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      handleSend();
    } else if (e.key === "Escape") {
      e.preventDefault();
      setText("");
    }
  }

  const placeholders = {
    question: "What's on your mind?",
    minimal: "",
    verb: "Capture a thought…",
    noun: "A note, a thought, a passing idea.",
  };

  const isEmpty = text.length === 0;
  const sendDisabled = isEmpty || status === "sending";

  return (
    <div className={`kn-editor kn-editor--${surface}`}>
      {/* the textarea — soft-rounded surface, system 16pt */}
      <div className={`kn-ta ${routeFlash && routing_anim === "pulse" ? "is-routing" : ""}`}>
        <textarea
          ref={taRef}
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={handleKey}
          placeholder={placeholders[empty_voice]}
          spellCheck={false}
          autoFocus
        />

        {/* threaded send overlay (variant) */}
        {send_feedback === "thread" && status === "sent" && (
          <div className="kn-thread" aria-hidden>
            <svg viewBox="0 0 200 8" preserveAspectRatio="none">
              <path d="M0 4 L 200 4" />
            </svg>
          </div>
        )}
      </div>

      {/* bottom row */}
      <div className="kn-row">
        <div className={`kn-mode ${routeFlash && routing_anim === "subtle" ? "is-flipped" : ""}`}>
          <ModeToggle
            mode={mode}
            onChange={(m) => setOverrideMode(m === computedAuto ? null : m)}
            variant={mode_toggle}
            auto={isAuto}
          />
        </div>

        <div className="kn-row__spacer" />

        <StatusPill status={status} message={errorMsg} />

        {/* send variants */}
        {send_feedback === "check" && (
          <SendButton disabled={sendDisabled} onClick={handleSend} sentFlash={sentFlash} />
        )}
        {send_feedback === "ribbon" && (
          <div className={`kn-ribbon-wrap ${sentFlash ? "is-sent" : ""}`}>
            <SendButton disabled={sendDisabled} onClick={handleSend} sentFlash={sentFlash} />
            <span className="kn-ribbon">→ {mode === "today" ? "Today" : "Inbox"}</span>
          </div>
        )}
        {send_feedback === "thread" && (
          <SendButton disabled={sendDisabled} onClick={handleSend} sentFlash={sentFlash} />
        )}
      </div>

      {/* auto-route chip — shown only on iOS where there's room */}
      {surface === "ios" && isAuto && !isEmpty && (
        <div className="kn-routinghint">
          <span>auto-routed by length</span>
        </div>
      )}
    </div>
  );
}

window.Editor = Editor;
window.autoMode = autoMode;
