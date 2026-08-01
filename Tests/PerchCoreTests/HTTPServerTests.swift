import Testing
@testable import PerchCore

@Suite("HTTPServer · tailnet boundary")
struct HTTPServerTailnetTests {
    @Test("only the 100.64.0.0/10 IPv4 range is trusted")
    func ipv4Range() {
        #expect(HTTPServer.isTailnetIPv4([100, 64, 0, 1]))
        #expect(HTTPServer.isTailnetIPv4([100, 127, 255, 254]))
        #expect(!HTTPServer.isTailnetIPv4([100, 63, 255, 255]))
        #expect(!HTTPServer.isTailnetIPv4([100, 128, 0, 1]))
        #expect(!HTTPServer.isTailnetIPv4([192, 168, 1, 2]))
    }

    @Test("only the fd7a:115c:a1e0::/48 IPv6 range is trusted")
    func ipv6Range() {
        #expect(HTTPServer.isTailnetIPv6([0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] + [UInt8](repeating: 0, count: 10)))
        #expect(!HTTPServer.isTailnetIPv6([0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe1] + [UInt8](repeating: 0, count: 10)))
        #expect(!HTTPServer.isTailnetIPv6([UInt8](repeating: 0, count: 16)))
    }
}
