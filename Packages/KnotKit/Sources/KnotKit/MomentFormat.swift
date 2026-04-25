import Foundation

/// Formats a `Date` using a [Moment.js display format string](https://momentjs.com/docs/#/displaying/format/).
///
/// This is the convention Obsidian's Daily Notes / Periodic Notes plugins use,
/// so users can paste in the same template they already have configured in
/// Obsidian (e.g. `YYYY-MM-DD`, `YYYY/MM/YYYY-MM-DD dddd`) and it will Just
/// Work — including when slashes are used to create subfolders in the
/// generated path.
///
/// Supported tokens (everything else is treated as a literal):
///
/// | Field          | Tokens                          |
/// |----------------|---------------------------------|
/// | Year           | `YYYY`, `YY`                    |
/// | Quarter        | `Q`, `Qo`                       |
/// | Month          | `MMMM`, `MMM`, `MM`, `Mo`, `M` |
/// | Day of year    | `DDDD`, `DDDo`, `DDD`           |
/// | Day of month   | `DD`, `Do`, `D`                 |
/// | Day of week    | `dddd`, `ddd`, `dd`, `do`, `d` |
/// | ISO weekday    | `E`                             |
/// | Week of year   | `ww`, `wo`, `w`                 |
/// | Hour 24h       | `HH`, `H`                       |
/// | Hour 12h       | `hh`, `h`                       |
/// | Hour 1-24      | `kk`, `k`                       |
/// | Minute         | `mm`, `m`                       |
/// | Second         | `ss`, `s`                       |
/// | Subsecond      | `SSS`, `SS`, `S`                |
/// | AM / PM        | `A`, `a`                        |
/// | Offset         | `Z`, `ZZ`                       |
/// | Unix epoch     | `X`, `x`                        |
///
/// Wrap a substring in `[...]` to mark it as a literal:
/// `[YYYY]/YYYY-MM-DD` produces `YYYY/2026-04-25`.
public enum MomentFormat {

    /// Formats `date` according to the given Moment-style `format` string.
    public static func string(
        from date: Date,
        format: String,
        locale: Locale = Locale(identifier: "en_US"),
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone

        let comps = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second,
             .weekday, .weekOfYear, .nanosecond, .quarter],
            from: date
        )
        // `dayOfYear` is available only on macOS 15+; compute it via
        // ordinality so we keep the package usable on older targets.
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 0

        var output = ""
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            let c = chars[i]

            // [...] literal escape, Moment-style.
            if c == "[" {
                i += 1
                while i < chars.count, chars[i] != "]" {
                    output.append(chars[i])
                    i += 1
                }
                if i < chars.count { i += 1 } // skip ']'
                continue
            }

            if let token = matchToken(in: chars, at: i) {
                output.append(value(
                    for: token,
                    components: comps,
                    dayOfYear: dayOfYear,
                    date: date,
                    locale: locale,
                    timeZone: timeZone
                ))
                i += token.count
                continue
            }

            output.append(c)
            i += 1
        }
        return output
    }

    // MARK: - Token table

    private static let tokensLongestFirst: [String] = [
        "YYYY", "YY",
        "MMMM", "MMM", "MM", "Mo", "M",
        "DDDo", "DDDD", "DDD", "Do", "DD", "D",
        "dddd", "ddd", "dd", "do", "d",
        "E",
        "wo", "ww", "w",
        "HH", "H",
        "hh", "h",
        "kk", "k",
        "mm", "m",
        "ss", "s",
        "SSS", "SS", "S",
        "A", "a",
        "ZZ", "Z",
        "X", "x",
        "Qo", "Q"
    ].sorted { $0.count > $1.count }

    private static func matchToken(in chars: [Character], at index: Int) -> String? {
        for token in tokensLongestFirst {
            let count = token.count
            guard chars.count - index >= count else { continue }
            let slice = chars[index..<(index + count)]
            if String(slice) == token { return token }
        }
        return nil
    }

    // MARK: - Token → value

    private static func value(
        for token: String,
        components c: DateComponents,
        dayOfYear: Int,
        date: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        switch token {
        // Year
        case "YYYY": return String(format: "%04d", c.year ?? 0)
        case "YY":   return String(format: "%02d", abs((c.year ?? 0) % 100))

        // Quarter
        case "Q":    return "\(c.quarter ?? 0)"
        case "Qo":   return ordinal(c.quarter ?? 0, locale: locale)

        // Month
        case "MMMM": return monthName(date, .full, locale, timeZone)
        case "MMM":  return monthName(date, .short, locale, timeZone)
        case "MM":   return String(format: "%02d", c.month ?? 0)
        case "Mo":   return ordinal(c.month ?? 0, locale: locale)
        case "M":    return "\(c.month ?? 0)"

        // Day of year
        case "DDDD": return String(format: "%03d", dayOfYear)
        case "DDDo": return ordinal(dayOfYear, locale: locale)
        case "DDD":  return "\(dayOfYear)"

        // Day of month
        case "DD":   return String(format: "%02d", c.day ?? 0)
        case "Do":   return ordinal(c.day ?? 0, locale: locale)
        case "D":    return "\(c.day ?? 0)"

        // Day of week (Moment: 0 = Sunday … 6 = Saturday)
        case "dddd": return weekdayName(date, .full, locale, timeZone)
        case "ddd":  return weekdayName(date, .short, locale, timeZone)
        case "dd":   return weekdayName(date, .veryShort, locale, timeZone)
        case "do":   return ordinal(((c.weekday ?? 1) - 1), locale: locale)
        case "d":    return "\(((c.weekday ?? 1) - 1))"

        // ISO day of week (1 = Monday … 7 = Sunday)
        case "E":    return "\(isoWeekday(c.weekday ?? 1))"

        // Week of year
        case "ww":   return String(format: "%02d", c.weekOfYear ?? 0)
        case "wo":   return ordinal(c.weekOfYear ?? 0, locale: locale)
        case "w":    return "\(c.weekOfYear ?? 0)"

        // Hour
        case "HH":   return String(format: "%02d", c.hour ?? 0)
        case "H":    return "\(c.hour ?? 0)"
        case "hh":   return String(format: "%02d", hour12(c.hour ?? 0))
        case "h":    return "\(hour12(c.hour ?? 0))"
        case "kk":   return String(format: "%02d", hour1to24(c.hour ?? 0))
        case "k":    return "\(hour1to24(c.hour ?? 0))"

        // Minute / Second
        case "mm":   return String(format: "%02d", c.minute ?? 0)
        case "m":    return "\(c.minute ?? 0)"
        case "ss":   return String(format: "%02d", c.second ?? 0)
        case "s":    return "\(c.second ?? 0)"

        // Subsecond
        case "SSS":  return String(format: "%03d", (c.nanosecond ?? 0) / 1_000_000)
        case "SS":   return String(format: "%02d", (c.nanosecond ?? 0) / 10_000_000)
        case "S":    return "\((c.nanosecond ?? 0) / 100_000_000)"

        // Meridiem
        case "A":    return (c.hour ?? 0) < 12 ? "AM" : "PM"
        case "a":    return (c.hour ?? 0) < 12 ? "am" : "pm"

        // Timezone offset
        case "Z":    return offset(timeZone, at: date, withColon: true)
        case "ZZ":   return offset(timeZone, at: date, withColon: false)

        // Unix
        case "X":    return "\(Int(date.timeIntervalSince1970))"
        case "x":    return "\(Int(date.timeIntervalSince1970 * 1000))"

        default:     return token
        }
    }

    // MARK: - Helpers

    private static func hour12(_ h: Int) -> Int {
        let v = h % 12
        return v == 0 ? 12 : v
    }

    private static func hour1to24(_ h: Int) -> Int {
        h == 0 ? 24 : h
    }

    /// Calendar uses 1=Sunday … 7=Saturday. ISO uses 1=Monday … 7=Sunday.
    private static func isoWeekday(_ weekday: Int) -> Int {
        ((weekday + 5) % 7) + 1
    }

    private static func ordinal(_ n: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private enum NameStyle {
        case full, short, veryShort
    }

    private static func monthName(_ date: Date, _ style: NameStyle, _ locale: Locale, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = tz
        switch style {
        case .full:      f.dateFormat = "MMMM"
        case .short:     f.dateFormat = "MMM"
        case .veryShort: f.dateFormat = "MMMMM"
        }
        return f.string(from: date)
    }

    private static func weekdayName(_ date: Date, _ style: NameStyle, _ locale: Locale, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = tz
        switch style {
        case .full:      f.dateFormat = "EEEE"
        case .short:     f.dateFormat = "EEE"
        case .veryShort: f.dateFormat = "EEEEEE"
        }
        return f.string(from: date)
    }

    private static func offset(_ tz: TimeZone, at date: Date, withColon: Bool) -> String {
        let total = tz.secondsFromGMT(for: date)
        let sign = total >= 0 ? "+" : "-"
        let absTotal = abs(total)
        let h = absTotal / 3600
        let m = (absTotal / 60) % 60
        return withColon
            ? String(format: "%@%02d:%02d", sign, h, m)
            : String(format: "%@%02d%02d", sign, h, m)
    }
}
