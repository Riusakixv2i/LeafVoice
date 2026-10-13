import XCTest
@testable import LeafVoice

@MainActor
final class ImportTests: XCTestCase {
    func testPlainTextImportCreatesBookAndNarrationSegments() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try "An opening sentence. Another chapter follows.".write(to:url,atomically:true,encoding:.utf8)
        defer { try? FileManager.default.removeItem(at:url) }
        let model = ReaderModel()
        model.importBook(url)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.book?.text,"An opening sentence. Another chapter follows.")
        XCTAssertNotNil(model.currentID)
        XCTAssertEqual(model.segmentIndex,0)
        XCTAssertNotNil(try? Data(contentsOf: FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("library.json")))
    }
    func testMissingFileShowsError() {
        let model = ReaderModel()
        model.importBook(URL(fileURLWithPath:"/nonexistent/test.txt"))
        XCTAssertNotNil(model.errorMessage)
    }
}
