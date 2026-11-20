// SP-4's spike app. Launched with -SP4SelfTest it prints the self-test's report and exits with
// the result. Launched with -SP4Live it runs one step of stage 2 against CloudKit (LiveRunner);
// only a team-signed iOS build can, and only in a simulator. Otherwise it shows the report.

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
        if CommandLine.arguments.contains("-SP4Live") {
            let arguments = CommandLine.arguments
            Task.detached {
                let code = await LiveRunner.run(arguments)
                exit(code)
            }
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
