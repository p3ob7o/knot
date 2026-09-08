import Foundation

public extension AppSettings {
    init(validated: ValidatedSettings) {
        self.init()
        dailyFolder = validated.dailyFolder.string
        inboxFolder = validated.inboxFolder.string
        dailyFilenameFormat = validated.dailyFilenameFormat
        inboxFilenameFormat = validated.inboxFilenameFormat
        switch validated.dailyTarget {
        case .endOfNote:
            dailyHeading = ""
        case .heading(let selector, _):
            dailyHeading = String(repeating: "#", count: selector.level) + " " + selector.title
        }
        dailyBulletFormat = validated.dailyBulletFormat
        routingMaxChars = validated.routingMaxChars
        routingRequiresSingleLine = validated.routingRequiresSingleLine
        attachmentFolderPath = validated.attachmentFolderPath
    }
}
