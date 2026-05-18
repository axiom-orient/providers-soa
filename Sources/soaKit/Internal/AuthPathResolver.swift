import Foundation

struct ResolvedCredentialLocation: Sendable {
    enum Kind: Sendable {
        case file(String)
        case keychain(service: String)
    }

    let descriptor: String
    let source: ResolvedAuthPathSource
    let kind: Kind
}

struct AuthPathResolver {
    static let maxAuthFileSizeBytes = 262_144

    let authPath: String?

    func resolve() throws -> ResolvedCredentialLocation {
        if let authPath = authPath?.nilIfEmpty {
            let resolved = resolvePath(authPath)
            return .init(descriptor: resolved, source: .explicitAuthPath, kind: .file(resolved))
        }
        #if os(macOS)
        let resolved = defaultMacOSAuthPath()
        return .init(descriptor: resolved, source: .platformDefaultMacOS, kind: .file(resolved))
        #else
        return .init(
            descriptor: "keychain://\(SoaCredentialStore.defaultService)/default",
            source: .platformDefaultKeychain,
            kind: .keychain(service: SoaCredentialStore.defaultService)
        )
        #endif
    }
}

#if os(macOS)
private func defaultMacOSAuthPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(SoaClient.defaultMacOSAuthRelativePath)
        .standardizedFileURL
        .path
}
#endif

private func resolvePath(_ raw: String) -> String {
    let expanded = NSString(string: raw).expandingTildeInPath
    if (expanded as NSString).isAbsolutePath {
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
    let cwd = FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: cwd).appendingPathComponent(expanded).standardizedFileURL.path
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
