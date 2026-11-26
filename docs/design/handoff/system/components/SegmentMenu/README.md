# SegmentMenu

The context menu of a segment and of a note, plus the undo capsule that follows a delete.

**Provide:** the actions this segment can take right now; omit the rest rather than disabling them.

- Order: Copy, Share…, Show original (voice), Move to its own note, Remove recording (voice), Retry (needs you), then Delete last as `role: .destructive`.
- Open it with long press or secondary click; on iPad and Mac also from the hover `ellipsis`. Mirror every item in `accessibilityActions`.
- A note's menu (toolbar `ellipsis`, stream row context menu): Copy note, Share note…, Delete note.
- After a delete, show the undo capsule for six seconds. Don't ask for confirmation.
