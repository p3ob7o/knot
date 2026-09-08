# Knot 0.2.0

Knot 0.2.0 rebuilds the macOS capture pipeline around durable local drafts, a transactional outbox, descriptor-relative vault writes, resumable setup, and an optional Gutenberg rich editor.

Highlights:

- Native quick capture remains available from the menu bar and global shortcut.
- Vault, Inbox, Daily folder, and heading setup resumes one step at a time.
- Captures are acknowledged only after durable local enqueue and can be retried, reviewed, or exported.
- Daily-note updates preserve original bytes on read, parse, containment, or coordination failures.
- Inbox notes and attachments use exclusive collision-safe publication.
- The rich editor uses a manifest-verified local bundle, a session-bound native bridge, source-preserving Markdown conversion, and private attachment staging.
- macOS is the supported product target. The iOS target is retained as an experimental compatibility build.

The app remains local-only. It performs no telemetry, account, sync, or network-dependent runtime work.
