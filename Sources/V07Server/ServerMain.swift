import Foundation
import V07API
import V07ServerKit

@main
struct V07ServerMain {
    static func main() async throws {
        if CommandLine.arguments.contains("--print-default-proofreading-prompt") {
            print(ServerPreferences.defaultProofreadingPrompt)
            return
        }
        if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
            print(ServerConfiguration.usage)
            return
        }
        let configuration = try ServerConfiguration.parse()
        try await V07HTTPServer.run(configuration: configuration)
    }
}
