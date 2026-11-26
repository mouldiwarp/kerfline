// USB serial to a real GRBL controller: POSIX termios at 115200 8N1, raw bytes.
// Port of packages/agent/src/transport.ts (SerialTransport, listPorts, autoDetectPort).

import Darwin
import Foundation
import IOKit
import IOKit.serial

public struct PortInfo: Sendable, Equatable {
    public var path: String
    public var manufacturer: String?
    public var vendorId: String?
    public var productId: String?
    public var likelyGrbl: Bool
}

// CH340 (FoxAlien and most hobby boards), FTDI, CP210x, Arduino, STM32 VCP (grblHAL).
private let grblVendors: Set<String> = ["1a86", "0403", "10c4", "2341", "2a03", "0483", "16c0"]

/// Serial ports on this Mac (callout devices), from the IOKit registry.
public func listPorts() -> [PortInfo] {
    var out: [PortInfo] = []
    guard let match = IOServiceMatching(kIOSerialBSDServiceValue) else { return out }
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else { return out }
    defer { IOObjectRelease(iter) }
    while case let service = IOIteratorNext(iter), service != 0 {
        defer { IOObjectRelease(service) }
        guard let path = property(service, kIOCalloutDeviceKey, parents: false) as? String else { continue }
        if path.range(of: "Bluetooth|debug-console", options: [.regularExpression, .caseInsensitive]) != nil { continue }
        let vendor = (property(service, "idVendor") as? Int).map { String(format: "%04x", $0) }
        let product = (property(service, "idProduct") as? Int).map { String(format: "%04x", $0) }
        let maker = property(service, "USB Vendor Name") as? String
        let likely = (vendor.map { grblVendors.contains($0) } ?? false)
            || path.range(of: "usbserial|wchusbserial|usbmodem", options: [.regularExpression, .caseInsensitive]) != nil
        out.append(PortInfo(path: path, manufacturer: maker, vendorId: vendor, productId: product, likelyGrbl: likely))
    }
    return out.sorted { $0.path < $1.path }
}

private func property(_ service: io_object_t, _ key: String, parents: Bool = true) -> Any? {
    let options: IOOptionBits = parents ? IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents) : 0
    return IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
}

/// The most likely GRBL port, preferring the /dev/cu.* callout device.
public func autoDetectPort() -> String? {
    let ports = listPorts().filter(\.likelyGrbl)
    return (ports.first { $0.path.hasPrefix("/dev/cu.") } ?? ports.first)?.path
}

public final class SerialPort: Transport, @unchecked Sendable {
    public let name: String
    public let simulated = false
    private let baud: speed_t
    private let pipe = EventPipe()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "swarfgrbl.serial")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    public var events: AsyncStream<TransportEvent> { pipe.stream }

    public init(_ path: String, baud: Int = 115200) {
        name = path
        self.baud = speed_t(baud)
    }

    public func open() async throws {
        let fd = Darwin.open(name, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fd < 0 { throw MachineError(String(cString: strerror(errno))) }
        // Exclusive: a second sender on the same port would corrupt both streams.
        if ioctl(fd, TIOCEXCL) != 0 {
            let e = errno
            Darwin.close(fd)
            throw MachineError("Port is busy: \(String(cString: strerror(e)))")
        }
        var t = termios()
        if tcgetattr(fd, &t) != 0 {
            let e = errno
            Darwin.close(fd)
            throw MachineError(String(cString: strerror(e)))
        }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
        t.c_cflag = (t.c_cflag & ~tcflag_t(CSIZE)) | tcflag_t(CS8)
        cfsetispeed(&t, baud)
        cfsetospeed(&t, baud)
        if tcsetattr(fd, TCSANOW, &t) != 0 {
            let e = errno
            Darwin.close(fd)
            throw MachineError(String(cString: strerror(e)))
        }
        tcflush(fd, TCIOFLUSH)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        lock.withLock {
            self.fd = fd
            self.source = src
        }
        src.resume()
    }

    private func readAvailable() {
        let fd = lock.withLock { self.fd }
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            pipe.continuation.yield(.data(Array(buf[..<n])))
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            // EOF or an error: the cable was pulled or the board reset off the bus.
            let err = n == 0 ? MachineError("The USB device went away") : MachineError(String(cString: strerror(errno)))
            shutdown()
            pipe.continuation.yield(.closed(err))
            pipe.continuation.finish()
        }
    }

    public func write(_ bytes: [UInt8]) {
        queue.async { [self] in
            let fd = lock.withLock { self.fd }
            guard fd >= 0 else { return }
            var off = 0
            var waited = 0
            while off < bytes.count {
                let n = bytes[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    off += n
                    waited = 0
                } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                    // Output buffer full: at 115200 baud it drains quickly. If it doesn't drain for
                    // 2 s the device has stopped reading; give up rather than block the port's queue.
                    waited += 1
                    if waited > 2000 { return }
                    usleep(1000)
                } else {
                    return
                }
            }
        }
    }

    public func close() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                let wasOpen = lock.withLock { fd >= 0 }
                shutdown()
                if wasOpen {
                    pipe.continuation.yield(.closed(nil))
                    pipe.continuation.finish()
                }
                c.resume()
            }
        }
    }

    private func shutdown() {
        let (fd, src) = lock.withLock {
            let r = (self.fd, self.source)
            self.fd = -1
            self.source = nil
            return r
        }
        src?.cancel()
        if fd >= 0 {
            // Discard unsent output first: closing a serial port otherwise waits for it to drain,
            // which never happens if the device has stopped reading.
            tcflush(fd, TCIOFLUSH)
            Darwin.close(fd)
        }
    }
}
