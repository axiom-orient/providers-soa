import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func formURLEncoded(_ pairs: [(String, String)]) -> Data {
    var components = URLComponents()
    components.queryItems = pairs.map { URLQueryItem(name: $0.0, value: $0.1) }
    return Data((components.percentEncodedQuery ?? "").utf8)
}

func jsonData(from value: JSONValue) throws -> Data {
    try value.encodedData()
}

func parseJSONBody(_ data: Data, status: Int) throws -> JSONValue {
    do {
        return try JSONValue.decode(from: data)
    } catch {
        throw SoaError.responsesRequestFailed(
            status: status,
            "response body was not valid JSON: \(error)"
        )
    }
}

func makeURL(_ raw: String) throws -> URL {
    guard let url = URL(string: raw) else {
        throw SoaError.invalidConfiguration("invalid URL \(String(reflecting: raw))")
    }
    return url
}
