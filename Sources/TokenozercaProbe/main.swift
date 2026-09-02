import Foundation
import TokenozercaCore

let discovery = SessionDiscovery()
let analyzer = SessionAnalyzer(discovery: discovery)
let pricing = PricingEngine()

func printReport(provider: Provider, url: URL) {
    print("\n=== \(provider.displayName) ===")
    do {
        let analysis = try analyzer.analyze(rootURL: url, provider: provider)
        let report = pricing.calculate(analysis)
        print("session=\(analysis.root.sessionID)")
        print("app_version=\(analysis.root.appVersion ?? "unknown")")
        print("sessions=\(analysis.sessions.count)")
        for session in analysis.sessions {
            print("session_usage[\(session.metadata.sessionID)]=\(session.totalUsage.total)")
        }
        print("input_uncached=\(analysis.totalUsage.inputUncached)")
        print("cached_read=\(analysis.totalUsage.inputCachedRead)")
        print("cache_write=\(analysis.totalUsage.cacheWrite5m + analysis.totalUsage.cacheWrite1h)")
        print("output=\(analysis.totalUsage.output)")
        print("reasoning=\(analysis.totalUsage.reasoningOrThinking)")
        print("total=\(analysis.totalUsage.total)")
        print("models=\(analysis.modelUsage.map(\.modelID).joined(separator: ","))")
        print("token_cost_usd=\(report.tokenCostUSD.map { NSDecimalNumber(decimal: $0).stringValue } ?? "unavailable")")
        print("accuracy=\(report.accuracy.rawValue)")
        print("warnings=\(report.warnings.count)")
    } catch {
        print("ERROR: \(error.localizedDescription)")
    }
}

let arguments = CommandLine.arguments
if arguments.count == 3, let provider = Provider(rawValue: arguments[1]) {
    printReport(provider: provider, url: URL(fileURLWithPath: arguments[2]))
} else {
    for provider in Provider.allCases {
        guard let candidate = discovery.recentDesktopSessions(provider: provider, limit: 1).first else {
            print("\n=== \(provider.displayName) ===")
            print("No desktop session found")
            continue
        }
        printReport(provider: provider, url: candidate.url)
    }
}
