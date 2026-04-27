import SwiftUI
import KnotKit

/// Confirmation strip that appears after `EditorModel.setVault` imports a
/// daily-note configuration from an Obsidian vault. Renders nothing when
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
                    Text("Imported daily-note settings from your vault")
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

    private func detailLine(for config: ImportedDailyConfig) -> String {
        let folder = config.folder.isEmpty ? "<vault root>" : config.folder
        return "Folder: \(folder)  ·  Filename: \(config.filenameFormat)  ·  \(sourceLabel(config.source))"
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
