import Foundation

/// A parsed HTTP request. Minimal on purpose — Claude Code hooks send small,
/// well-formed `POST` bodies with `Content-Length`, so we only support that.
public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]   // keys lowercased
    public let body: Data
    public let remoteIsLoopback: Bool

    public var bodyString: String { String(data: body, encoding: .utf8) ?? "" }
}

/// An HTTP response we serialize back onto the connection. The handler decides
/// *when* to return one — which is what makes the Phase 4 blocking permission
/// hold possible (the response is sent only once the user taps Allow/Deny).
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func ok(_ text: String = "OK") -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
    }

    public static func notFound() -> HTTPResponse {
        HTTPResponse(status: 404, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data("not found".utf8))
    }

    /// The correct acknowledgement for a *read-only* hook: a `2xx` with an
    /// EMPTY body. Per the verified HTTP-hook contract, Claude Code treats this
    /// as "success, no-op" and injects nothing into the conversation. (A text
    /// body would be added to the model's context as `additionalContext`; a
    /// non-2xx status is a *silently non-blocking* error.)
    public static func hookAck() -> HTTPResponse {
        HTTPResponse(status: 200)
    }

    /// Serialize a JSON-encodable dictionary. Used in Phase 4 for the
    /// `hookSpecificOutput` / `permissionDecision` response.
    public static func jsonObject(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    /// Raw HTTP/1.1 bytes for this response, with `Connection: close`.
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        var hdrs = headers
        hdrs["Content-Length"] = String(body.count)
        hdrs["Connection"] = "close"
        for (k, v) in hdrs {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 408: return "Request Timeout"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}

/// Incremental HTTP/1.1 request parser. Bytes arrive across multiple socket
/// reads; we buffer until the header terminator is seen and the full
/// `Content-Length` body has been received.
struct HTTPRequestParser {
    enum Result {
        case needMore
        case complete(method: String, path: String, headers: [String: String], body: Data)
        case failed(String)
    }

    private var buffer = Data()
    private static let terminator = Data("\r\n\r\n".utf8)

    mutating func append(_ data: Data) -> Result {
        buffer.append(data)
        guard let range = buffer.range(of: Self.terminator) else {
            // Guard against unbounded growth from a misbehaving client.
            if buffer.count > 1_048_576 { return .failed("header too large") }
            return .needMore
        }

        let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .failed("non-utf8 header")
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .failed("empty request") }

        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count >= 2 else { return .failed("bad request line") }
        let method = requestLine[0]
        let path = requestLine[1]

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // Reject a negative Content-Length (Int("-1") parses fine and would make
        // the offset math form an inverted Range → hard crash) and cap the body so
        // a local process can't exhaust memory. Hook payloads are tiny.
        guard let contentLength = Int(headers["content-length"] ?? "0"), contentLength >= 0 else {
            return .failed("bad content-length")
        }
        guard contentLength <= 8_388_608 else { return .failed("body too large") }
        let bodyStart = range.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return .needMore }

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        return .complete(method: method, path: path, headers: headers, body: body)
    }
}
