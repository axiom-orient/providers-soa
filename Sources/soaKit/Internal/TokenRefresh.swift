import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct RefreshedTokens: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let accountID: String?
}

func refreshChatGPTTokens(
    session: URLSession,
    issuer: String,
    clientID: String,
    refreshToken: String
) async throws -> RefreshedTokens {
    let endpoint = issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/oauth/token"
    var request = URLRequest(url: try makeURL(endpoint))
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formURLEncoded([
        ("grant_type", "refresh_token"),
        ("refresh_token", refreshToken),
        ("client_id", clientID),
    ])

    do {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SoaError.transport("refresh-token exchange did not return an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SoaError.authRefreshFailed(
                "refresh-token exchange returned status \(http.statusCode): \(safeJSONErrorMessage(String(decoding: data, as: UTF8.self)))"
            )
        }
        let parsed = try parseJSONBody(data, status: http.statusCode)
        guard let accessToken = parsed["access_token"]?.stringValue?.nilIfEmpty,
              let nextRefreshToken = parsed["refresh_token"]?.stringValue?.nilIfEmpty
        else {
            throw SoaError.authRefreshFailed("refresh-token exchange returned invalid JSON")
        }
        let idToken = parsed["id_token"]?.stringValue?.nilIfEmpty
        let accountID = parsed["account_id"]?.stringValue?.nilIfEmpty ?? idToken.flatMap(chatGPTAccountIDFromJWT)
        return RefreshedTokens(
            accessToken: accessToken,
            refreshToken: nextRefreshToken,
            idToken: idToken,
            accountID: accountID
        )
    } catch let error as SoaError {
        throw error
    } catch {
        throw SoaError.authRefreshFailed(
            "refresh-token exchange transport failure against \(sanitizeURLForDisplay(endpoint)): \(error.localizedDescription)"
        )
    }
}
