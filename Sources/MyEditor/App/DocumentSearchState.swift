import Foundation
import Observation

@Observable @MainActor
final class DocumentSearchState {
    enum Mode { case find, replace }
    var query = ""
    var replacement = ""
    var mode: Mode = .find
    var showsReplacement = false
    var count = 0
    var current = 0
    var isSearching = false
    var isReplacing = false
    var isFocused = false
    var message: String?
    var focusRequest = 0
    private(set) var requestID = 0
    private(set) var pendingClearID: Int?
    private(set) var resultSequence: UInt64 = 0

    var counter: String { query.isEmpty ? "" : "\(current)/\(count)" }
    var canReplace: Bool { count > 0 && !isSearching && !isReplacing }

    func nextRequest() -> Int {
        requestID += 1
        isSearching = !query.isEmpty
        pendingClearID = nil
        message = nil
        return requestID
    }

    func receive(_ body: [String: Any]) {
        guard (body["requestID"] as? NSNumber)?.intValue == requestID,
            body["query"] as? String == query,
            let sequence = (body["sequence"] as? NSNumber)?.uint64Value,
            sequence >= resultSequence
        else { return }
        resultSequence = sequence
        count = (body["count"] as? NSNumber)?.intValue ?? 0
        current = (body["current"] as? NSNumber)?.intValue ?? 0
        isSearching = false
    }

    @discardableResult func endSearch() -> Int {
        requestID += 1
        resultSequence = 0
        query = ""
        replacement = ""
        mode = .find
        showsReplacement = false
        count = 0
        current = 0
        isSearching = false
        isReplacing = false
        pendingClearID = requestID
        message = nil
        return requestID
    }

    func acknowledgeClear(_ request: Int) {
        guard requestID == request, query.isEmpty, pendingClearID == request else { return }
        pendingClearID = nil
    }

    func resetForReload() {
        resultSequence = 0
        count = 0
        current = 0
        isSearching = !query.isEmpty
    }
}
