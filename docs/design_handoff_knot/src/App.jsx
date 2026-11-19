// Knot — main app. Locked-in design with light/dark + accent + brand mark tweaks.

function App() {
  const [tw, setTweak] = useTweaks(/*EDITMODE-BEGIN*/{
    "theme": "dark"
  }/*EDITMODE-END*/);

  // Accent locked: 75% gray toward white (#bfbfbf)
  React.useEffect(() => {
    document.documentElement.style.setProperty("--accent", "#bfbfbf");
    document.documentElement.style.setProperty("--accent-soft", "rgba(191,191,191,0.18)");
    document.documentElement.style.setProperty("--accent-strong", "#cccccc");
  }, []);

  // Locked-in choices
  const editorProps = {
    mode_toggle: "icons",       // 03B
    send_feedback: "check",     // 04A
    empty_voice: "minimal",     // 08B
    routing_anim: "subtle",
  };

  return (
    <>
      <DesignCanvas
        title="Knot — final direction"
        subtitle="Iconified mode toggle · saved chip · minimal detached chrome · minimal empty state"
      >

        <DCSection id="brand" title="01 · Brand mark">
          <DCArtboard id="marks" label="Knot — brand mark" width={1080} height={300}>
            <MarkShowcase theme={tw.theme} />
          </DCArtboard>
          <DCArtboard id="menubar" label="In situ — macOS menu bar" width={1080} height={140}>
            <div style={{ padding: 20 }}>
              <MenuBarSim popoverOpen />
            </div>
          </DCArtboard>
        </DCSection>

        <DCSection id="popover" title="02 · macOS popover — primary surface">
          <DCArtboard id="pop-empty" label="Empty (auto-focused)" width={500} height={400}>
            <PopoverShell theme={tw.theme}>
              <Editor surface="popover" {...editorProps} />
            </PopoverShell>
          </DCArtboard>
          <DCArtboard id="pop-typing" label="Typing — short note → Today" width={500} height={400}>
            <PopoverShell theme={tw.theme}>
              <Editor surface="popover" {...editorProps} initialText="brief Anna re: Q3 scope before standup" />
            </PopoverShell>
          </DCArtboard>
          <DCArtboard id="pop-routed" label="Crossed threshold → Inbox" width={500} height={400}>
            <PopoverShell theme={tw.theme}>
              <Editor surface="popover" {...editorProps} initialText={"# Project plan\n\n- scope is roughly 4 weeks\n- next: brief Anna and write the kickoff doc, share before Friday"} />
            </PopoverShell>
          </DCArtboard>
          <DCArtboard id="pop-sending" label="Sending" width={500} height={400}>
            <PopoverShell theme={tw.theme}>
              <Editor surface="popover" {...editorProps} initialText="meet w/ design at 4 — bring the wireframes" initialStatus="sending" />
            </PopoverShell>
          </DCArtboard>
          <DCArtboard id="pop-sent" label="Sent · saved confirmation" width={500} height={400}>
            <PopoverShell theme={tw.theme}>
              <Editor surface="popover" {...editorProps} initialText="" initialStatus="sent" />
            </PopoverShell>
          </DCArtboard>
          <DCArtboard id="pop-error" label="Error — vault write failed" width={500} height={400}>
            <PopoverShell theme={tw.theme}>
              <Editor surface="popover" {...editorProps} initialText="quick thought before the call" initialStatus="error" initialErrorMsg="Couldn't write — vault permission lost" />
            </PopoverShell>
          </DCArtboard>
        </DCSection>

        <DCSection id="detached" title="03 · Detached window — minimal chrome">
          <DCArtboard id="det-empty" label="Empty" width={520} height={420}>
            <DetachedShell theme={tw.theme} chrome="minimal">
              <Editor surface="window" isDetached {...editorProps} />
            </DetachedShell>
          </DCArtboard>
          <DCArtboard id="det-typing" label="Typing" width={520} height={420}>
            <DetachedShell theme={tw.theme} chrome="minimal">
              <Editor surface="window" isDetached {...editorProps} initialText="floating: opens with ⌃⌥K, lives across spaces" />
            </DetachedShell>
          </DCArtboard>
        </DCSection>

        <DCSection id="onboarding" title="04 · Onboarding (first launch)">
          <DCArtboard id="onb-popover" label="macOS popover — first launch" width={500} height={400}>
            <PopoverShell theme={tw.theme}><Onboarding surface="popover" /></PopoverShell>
          </DCArtboard>
          <DCArtboard id="onb-window" label="macOS detached — first launch" width={520} height={420}>
            <DetachedShell theme={tw.theme} chrome="minimal"><Onboarding surface="window" /></DetachedShell>
          </DCArtboard>
        </DCSection>

        <DCSection id="settings" title="05 · Settings (macOS)">
          <DCArtboard id="settings-1" label="Settings window" width={580} height={780}>
            <Settings theme={tw.theme} />
          </DCArtboard>
        </DCSection>

      </DesignCanvas>

      <TweaksPanel title="Tweaks">
        <TweakSection label="Theme" />
        <TweakRadio label="Appearance" value={tw.theme} onChange={(v) => setTweak("theme", v)}
          options={[{value:"dark", label:"Dark"}, {value:"light", label:"Light"}]} />
      </TweaksPanel>
    </>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
