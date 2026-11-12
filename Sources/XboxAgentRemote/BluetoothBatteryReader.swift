import Foundation
import Darwin
import RemoteCore

/// Runs at most one bounded system report off the main thread. No report is logged
/// or saved; completion contains only the matched controller's optional level.
final class BluetoothBatteryReader {
    private let queue = DispatchQueue(label: "JoyCode.bluetooth-battery", qos: .utility)
    private let lock = NSLock()
    private var activeJob: ReadJob?

    /// False means a previously cancelled job is still cleaning up; no callback.
    @discardableResult
    func read(matchingName: String, completion: @escaping (Double?) -> Void) -> Bool {
        lock.lock()
        guard activeJob == nil else { lock.unlock(); return false }
        let job = ReadJob()
        activeJob = job
        lock.unlock()
        queue.async { [weak self] in
            let level = job.run(matchingName: matchingName)
            guard let self else { return }
            self.lock.lock()
            if self.activeJob === job { self.activeJob = nil }
            self.lock.unlock()
            DispatchQueue.main.async { completion(level) }
        }
        return true
    }

    func cancel() {
        lock.lock()
        let job = activeJob
        lock.unlock()
        job?.cancel()
    }

    deinit { cancel() }

    private final class ReadJob {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        private var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func run(matchingName: String) -> Double? {
            guard !isCancelled else { return nil }
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json", "-timeout", "5", "-detailLevel", "mini"]
            // One pipe avoids stdout/stderr deadlock and caps their combined size.
            // Unexpected diagnostics make JSON invalid, so we fail closed.
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            let handle = pipe.fileHandleForReading
            let descriptor = handle.fileDescriptor
            defer {
                try? handle.close()
                try? pipe.fileHandleForWriting.close()
            }
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            do { try process.run() } catch { return nil }
            try? pipe.fileHandleForWriting.close()
            defer { stopAndReap(process) }

            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            var reachedEOF = false
            while true {
                guard !isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                if reachedEOF {
                    if !process.isRunning { break }
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }
                var item = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                let ready = poll(&item, 1, 100)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                guard ready > 0 else { continue }
                if item.revents & Int16(POLLNVAL) != 0 { return nil }
                while true {
                    let count = buffer.withUnsafeMutableBytes { bytes in
                        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                    }
                    if count > 0 {
                        guard output.count + count <= 1_048_576 else { return nil }
                        output.append(contentsOf: buffer.prefix(count))
                    } else if count == 0 {
                        reachedEOF = true
                        break
                    } else {
                        if errno == EINTR { continue }
                        if errno == EAGAIN || errno == EWOULDBLOCK { break }
                        return nil
                    }
                }
            }
            process.waitUntilExit()
            guard !isCancelled, process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
            return BluetoothBatteryReport.level(in: output, matchingName: matchingName)
        }

        private func stopAndReap(_ process: Process) {
            if process.isRunning {
                process.terminate()
                let deadline = ProcessInfo.processInfo.systemUptime + 0.25
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning {
                    // Only the exact Process launched above is eligible for cleanup.
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            process.waitUntilExit()
        }
    }
}
