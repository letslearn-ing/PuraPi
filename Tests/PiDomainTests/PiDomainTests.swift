import XCTest
@testable import PiDomain

final class PiDomainTests: XCTestCase {
    func testWorkspaceDescriptorNormalizesRoot() {
        let descriptor = WorkspaceDescriptor(rootURL: URL(fileURLWithPath: "/tmp/example/../example"))
        XCTAssertEqual(descriptor.rootURL.path, "/tmp/example")
        XCTAssertEqual(descriptor.displayName, "example")
    }

    func testConversationItemHasStableIdentity() {
        let id = UUID()
        let item = ConversationItem(id: id, kind: .assistant, text: "hello")
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.kind, .assistant)
    }
}
