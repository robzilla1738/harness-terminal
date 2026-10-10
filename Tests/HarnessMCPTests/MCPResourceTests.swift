import XCTest
import HarnessCore
@testable import HarnessMCP

final class MCPResourceTests: XCTestCase {
    func testPaginationKeepsAllTerminalIdentitiesAndOmitsPreviewAndLinkedDuplicates() throws {
        var tabs = (0..<4100).map { _ in Tab(cwd: "/tmp") }
        var preview = PaneLeaf(cwd: "/tmp"); preview.content = .preview(PreviewSpecification(url: "http://localhost:3000"))
        tabs.append(Tab(rootPane: .leaf(preview))); tabs.append(tabs[0])
        var snapshot = SessionSnapshot(); snapshot.workspaces[0].sessions[0].tabs = tabs
        var cursor: String?, identities: Set<String> = [], count = 0
        repeat {
            let result = try MCPResourcePageBuilder.page(snapshot, cursor: cursor)
            for resource in result.resources { XCTAssertTrue(identities.insert(resource.uri).inserted); count += 1 }
            cursor = result.nextCursor
            snapshot.revision += 1
        } while cursor != nil
        XCTAssertEqual(count, 4100)
        XCTAssertFalse(identities.contains("harness://pane/" + preview.surfaceID.uuidString + "/screen"))
        XCTAssertThrowsError(try MCPResourcePageBuilder.page(snapshot, cursor: "bad cursor"))
    }
}
