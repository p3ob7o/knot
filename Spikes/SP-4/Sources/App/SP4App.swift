// SP-4's spike app. In stage 1 it runs the self-test and shows its report; it never opens a
// container. Launched with -SP4SelfTest it prints the report and exits with the result.

import SwiftUI

@main
struct SP4App: App {
    init() {
        if CommandLine.arguments.contains("-SP4SelfTest") {
            var harness = Harness()
            harness.run()
            print(harness.report())
            fflush(stdout)
            exit(harness.failed == 0 ? 0 : 1)
        }
    }

    var body: some Scene {
        WindowGroup {
            ReportView()
        }
    }
}

struct ReportView: View {
    @State private var report = ""

    var body: some View {
        ScrollView {
            Text(report)
                .font(.body.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .task {
            var harness = Harness()
            harness.run()
            report = harness.report()
        }
    }
}
