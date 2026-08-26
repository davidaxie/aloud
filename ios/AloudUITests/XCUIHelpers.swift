import XCTest

/// Shared helpers for every UI-test class. One copy only: a fix to the
/// waiter's semantics (predicate shape, polling, Optional-wrapped values on
/// a new runtime, …) lands everywhere at once instead of in whichever file
/// happened to flake.
extension XCTestCase {

    /// Wait until the element's accessibility `value` equals `expected`.
    func waitForValue(_ expected: String, of element: XCUIElement,
                      timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// The element's accessibility `value` as a string ("" when absent).
    func stringValue(of element: XCUIElement) -> String {
        (element.value as? String) ?? ""
    }
}
