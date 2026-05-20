import Foundation

struct ResolvedCredentialLocation: Sendable {
    let descriptor: String
    let source: ResolvedAuthPathSource
    let path: String
}

struct AuthPathResolver {
    static let maxAuthFileSizeBytes = 262_144

    let authPath: String?
    let authHome: String?

    func resolve() throws -> ResolvedCredentialLocation {
        if let authPath = authPath?.nilIfEmpty {
            let resolved = try resolveAbsolutePath(authPath, label: "authPath")
            return .init(descriptor: resolved, source: .explicitAuthPath, path: resolved)
        }
        if let authHome = authHome?.nilIfEmpty {
            let resolved = try resolveAbsolutePath(authHome, label: "authHome")
            let path = URL(fileURLWithPath: resolved).appendingPathComponent("auth.json").standardizedFileURL.path
            return .init(descriptor: path, source: .explicitAuthHome, path: path)
        }
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?.nilIfEmpty {
            let resolved = try resolveAbsolutePath(codexHome, label: "CODEX_HOME")
            let path = URL(fileURLWithPath: resolved).appendingPathComponent("auth.json").standardizedFileURL.path
            return .init(descriptor: path, source: .codexHomeEnv, path: path)
        }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(SoaClient.defaultMacOSAuthRelativePath)
            .standardizedFileURL
            .path
        return .init(descriptor: path, source: .defaultHome, path: path)
    }
}

private func resolveAbsolutePath(_ raw: String, label: String) throws -> String {
    let expanded = NSString(string: raw).expandingTildeInPath
    guard (expanded as NSString).isAbsolutePath else {
        throw SoaError.invalidConfiguration("\(label) must be an absolute path")
    }
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
}

func readAuthJSON(path: String) throws -> JSONValue {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else {
        throw SoaError.authMissing(path: path)
    }

    do {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values.isRegularFile == false {
            throw SoaError.authReadFailed(path: path, "auth.json must be a regular file")
        }
        if let fileSize = values.fileSize, fileSize > AuthPathResolver.maxAuthFileSizeBytes {
            throw SoaError.authReadFailed(
                path: path,
                "auth.json exceeds \(AuthPathResolver.maxAuthFileSizeBytes) bytes"
            )
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try JSONValue.decode(from: data)
    } catch let error as DecodingError {
        throw SoaError.authMalformed("could not parse auth.json as JSON: \(error)")
    } catch let error as SoaError {
        throw error
    } catch {
        throw SoaError.authReadFailed(path: path, error.localizedDescription)
    }
}
