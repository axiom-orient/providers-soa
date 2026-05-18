import Foundation

func persistRefreshedAuth(path: String, parsed: ParsedAuthFile, refreshed: RefreshedAuthPayload) throws {
    let rewritten = try rewriteRefreshedAuthJSON(parsed: parsed, refreshed: refreshed)
    let data = try rewritten.encodedData(prettyPrinted: true)
    let url = URL(fileURLWithPath: path)
    do {
        try data.write(to: url, options: [.atomic])
        try hardenCredentialFilePermissions(path: path)
    } catch let error as SoaError {
        throw error
    } catch {
        throw SoaError.authRefreshFailed(
            "refreshed credential could not be persisted to \(path): \(error.localizedDescription)",
            path: path
        )
    }
}

private func hardenCredentialFilePermissions(path: String) throws {
    #if os(Windows)
    _ = path
    #else
    do {
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: path)
    } catch {
        throw SoaError.authRefreshFailed(
            "refreshed credential permissions could not be restricted for \(path): \(error.localizedDescription)",
            path: path
        )
    }
    #endif
}

func persistBrowserReloginAuth(path: String, document: JSONValue) throws {
    let data = try document.encodedData(prettyPrinted: true)
    let url = URL(fileURLWithPath: path)
    do {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try hardenCredentialFilePermissions(path: path)
    } catch let error as SoaError {
        throw error
    } catch {
        throw SoaError.persistFailed(path: path, error.localizedDescription)
    }
}
