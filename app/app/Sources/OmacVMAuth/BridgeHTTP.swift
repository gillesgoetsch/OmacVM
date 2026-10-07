import Foundation

/// The HTTP/1.1 the app speaks to OmacVM Bridge on its relay socket (the
/// control centre's requests and Touch ID's): one request per connection,
/// and the Bridge answers with Content-Length and closes.
public enum BridgeHTTP {
    public static func request(method: String, path: String, headers: [(String, String)], body: Data?) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: omacvm-bridge\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body?.count ?? 0)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + (body ?? Data())
    }

    public struct Response: Equatable {
        public let status: Int
        /// Header names in lower case; a repeated name keeps its last value.
        public let headers: [String: String]
        public let body: Data
    }

    /// The Bridge's answer, or nil (none, cut short, not HTTP).
    public static func parse(_ data: Data) -> Response? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2, first[0].hasPrefix("HTTP/1."), let status = Int(first[1]), (100...599).contains(status) else { return nil }
        var body = Data(data[end.upperBound...]), headers: [String: String] = [:]
        for l in lines.dropFirst() {
            let kv = l.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let k = kv[0].lowercased(), v = kv[1].trimmingCharacters(in: .whitespaces)
            headers[k] = v
            if k == "content-length" {
                guard let n = Int(v), n >= 0, body.count >= n else { return nil }   // cut short, or not a length
                body = body.prefix(n)
            }
        }
        return Response(status: status, headers: headers, body: body)
    }
}
