import SwiftUI
import KnotKit

/// Confirmation strip that appears after `EditorModel.setVault` imports
/// Obsidian configuration from a vault. Renders nothing when
/// `model.lastImport` is `nil` or `.noConfigFound`.
struct VaultImportBanner: View {
    @Bindable var model: EditorModel

    var body: some View {
        if case .imported(let config, _) = model.lastImport {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Imported Obsidian settings from your vault")
                        .font(.system(size: 12, weight: .semibold))
                    Text(detailLine(for: config))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Button("Undo") {
                        model.undoLastImport()
                    }
                    .buttonStyle(.borderless)
                    Button("Dismiss") {
                        model.dismissLastImport()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.background.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func detailLine(for config: ImportedVaultConfig) -> String {
        var parts: [String] = []
        if let daily = config.daily {
            let folder = daily.folder.isEmpty ? "<vault root>" : daily.folder
            parts.append("Daily: \(folder) / \(daily.filenameFormat) (\(sourceLabel(daily.source)))")
        }
        if let attachment = config.attachment {
            let folder = attachment.attachmentFolderPath.isEmpty
                ? "<vault root>"
                : attachment.attachmentFolderPath
            parts.append("Attachments: \(folder)")
        }
        return parts.joined(separator: "  ·  ")
    }

    private func sourceLabel(_ source: ImportedDailyConfig.Source) -> String {
        switch source {
        case .periodicNotes:
            return "Periodic Notes"
        case .coreDailyNotes:
            return "Core Daily Notes"
        }
    }
}
