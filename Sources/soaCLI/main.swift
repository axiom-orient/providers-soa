import soaCLIKit
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct SoaTool {
    static func main() async {
        let app = CLIApplication(progress: { text in
            FileHandle.standardOutput.write(Data(text.utf8))
        })
        let result = await app.run(arguments: CommandLine.arguments)
        if !result.stdout.isEmpty {
            FileHandle.standardOutput.write(Data(result.stdout.utf8))
        }
        if !result.stderr.isEmpty {
            FileHandle.standardError.write(Data(result.stderr.utf8))
        }
        exit(result.exitCode)
    }
}
