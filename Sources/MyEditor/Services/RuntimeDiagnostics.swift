import Darwin
import Foundation
import OSLog

/// Opt-in local acceptance measurements. Never records paths or manuscript contents.
/// Enabled only by the build script's --metrics flag, with output inside .cache/validation/<build>/<run>.
@MainActor enum RuntimeDiagnostics {
    private static let runID = UUID().uuidString
    private static let logger = Logger(subsystem: "local.novelreader.app", category: "performance")

    static func record(_ event: String, documents: Int, documentBytes: Int, released: Bool? = nil) {
        guard
            let directory = Bundle.main.object(forInfoDictionaryKey: "NRDiagnosticsDirectory")
                as? String
        else { return }
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var process = proc_bsdinfo()
        let processStatus = proc_pidinfo(
            getpid(), PROC_PIDTBSDINFO, 0, &process, Int32(MemoryLayout<proc_bsdinfo>.size))
        let started = Double(process.pbi_start_tvsec) + Double(process.pbi_start_tvusec) / 1_000_000
        let milliseconds = processStatus > 0 ? (Date().timeIntervalSince1970 - started) * 1000 : -1
        let fdBytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: max(1, Int(fdBytes) / MemoryLayout<proc_fdinfo>.size + 16))
        let actualFDBytes = descriptors.withUnsafeMutableBufferPointer {
            proc_pidinfo(
                getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress,
                Int32($0.count * MemoryLayout<proc_fdinfo>.size))
        }
        var entry: [String: Any] = [
            "run": runID, "event": event, "documents": documents, "documentBytes": documentBytes,
            "processElapsedMilliseconds": milliseconds,
            "physicalFootprintBytes": status == KERN_SUCCESS ? vm.phys_footprint : 0,
            "residentBytes": status == KERN_SUCCESS ? vm.resident_size : 0,
            "fileDescriptors": Int(actualFDBytes) / MemoryLayout<proc_fdinfo>.size,
            "scrollEventMonitors": MarkdownWebEditor.Coordinator.activeWheelMonitors,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        if let released { entry["closedSessionReleased"] = released }
        logger.info(
            "\(event, privacy: .public): documents=\(documents), memory=\(vm.phys_footprint)")
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        else { return }
        let destination = URL(fileURLWithPath: directory).appendingPathComponent(
            "runtime-metrics.jsonl")
        Task { await MetricsWriter.shared.append(data, to: destination) }
    }
}

private actor MetricsWriter {
    static let shared = MetricsWriter()
    func append(_ data: Data, to url: URL) {
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([10]))
            try handle.close()
        } catch {
            // Diagnostics never interrupts reading or document saves.
        }
    }
}
