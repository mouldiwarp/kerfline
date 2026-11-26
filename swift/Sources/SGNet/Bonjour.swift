// Bonjour: the hub advertises `_swarfgrbl._tcp` (with TXT version=2) so the agent and SwarfPath can
// find it without an address; the agent browses for it. Uses the dnssd C API on a dispatch queue.

import Foundation
import SGCore
import dnssd

/// A hub found on the network.
public struct FoundHub: Sendable, Equatable {
    public var name: String
    public var host: String
    public var port: Int
    public var version: Int?
}

private let bonjourQueue: DispatchQueue = {
    let q = DispatchQueue(label: "swarfgrbl.bonjour")
    q.setSpecific(key: onBonjourQueueKey, value: true)
    return q
}()
private let onBonjourQueueKey = DispatchSpecificKey<Bool>()

/// Run `body` on the Bonjour queue and wait. Inline if already on it: a browser's last reference
/// can go in one of its own callbacks, and `deinit` → `stop()` must not `sync` onto its own queue.
private func onBonjourQueue(_ body: () -> Void) {
    if DispatchQueue.getSpecific(key: onBonjourQueueKey) == true { body() } else { bonjourQueue.sync(execute: body) }
}

/// Keeps a service registered until stopped.
public final class BonjourAdvert: @unchecked Sendable {
    private var ref: DNSServiceRef?

    /// Advertise `name` on `port`. Returns nil if mDNSResponder refuses.
    public init?(name: String, port: Int, type: String = hubServiceType, txt: [String: String] = ["version": "\(linkProtocolVersion)"]) {
        var record = TXTRecordRef()
        TXTRecordCreate(&record, 0, nil)
        defer { TXTRecordDeallocate(&record) }
        for (k, v) in txt {
            let bytes = Array(v.utf8)
            _ = TXTRecordSetValue(&record, k, UInt8(bytes.count), bytes)
        }
        var r: DNSServiceRef?
        let err = DNSServiceRegister(
            &r, 0, 0, name, type, nil, nil, UInt16(port).bigEndian, TXTRecordGetLength(&record), TXTRecordGetBytesPtr(&record),
            { _, _, _, _, _, _, _ in }, nil)
        guard err == kDNSServiceErr_NoError, let r else { return nil }
        DNSServiceSetDispatchQueue(r, bonjourQueue)
        ref = r
    }

    public func stop() {
        onBonjourQueue {
            if let ref { DNSServiceRefDeallocate(ref) }
            ref = nil
        }
    }

    deinit { stop() }
}

/// Browse for hubs and resolve each one found. `onFound` is called (on a private queue) for each
/// resolved hub; `onLost` with the service name when it goes away.
public final class BonjourBrowser: @unchecked Sendable {
    private var browseRef: DNSServiceRef?
    private var resolves: [String: DNSServiceRef] = [:]
    private let onFound: @Sendable (FoundHub) -> Void
    private let onLost: @Sendable (String) -> Void
    private let type: String

    public init(type: String = hubServiceType, onFound: @escaping @Sendable (FoundHub) -> Void, onLost: @escaping @Sendable (String) -> Void = { _ in }) {
        self.type = type
        self.onFound = onFound
        self.onLost = onLost
    }

    public func start() {
        onBonjourQueue {
            var r: DNSServiceRef?
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            let err = DNSServiceBrowse(&r, 0, 0, type, nil, { _, flags, iface, err, name, type, domain, ctx in
                guard err == kDNSServiceErr_NoError, let ctx, let name, let type, let domain else { return }
                let me = Unmanaged<BonjourBrowser>.fromOpaque(ctx).takeUnretainedValue()
                me.browsed(added: flags & kDNSServiceFlagsAdd != 0, iface: iface, name: String(cString: name), type: String(cString: type), domain: String(cString: domain))
            }, ctx)
            guard err == kDNSServiceErr_NoError, let r else { return }
            DNSServiceSetDispatchQueue(r, bonjourQueue)
            browseRef = r
        }
    }

    public func stop() {
        onBonjourQueue {
            if let browseRef { DNSServiceRefDeallocate(browseRef) }
            browseRef = nil
            for r in resolves.values { DNSServiceRefDeallocate(r) }
            resolves = [:]
            for c in contexts { Unmanaged<ResolveContext>.fromOpaque(c).release() }
            contexts = []
        }
    }

    deinit { stop() }

    /// On the bonjour queue.
    private func browsed(added: Bool, iface: UInt32, name: String, type: String, domain: String) {
        guard added else {
            if let r = resolves.removeValue(forKey: name) { DNSServiceRefDeallocate(r) }
            onLost(name)
            return
        }
        if let r = resolves.removeValue(forKey: name) { DNSServiceRefDeallocate(r) }
        var r: DNSServiceRef?
        let box = Unmanaged.passRetained(ResolveContext(browser: self, name: name)).toOpaque()
        let err = DNSServiceResolve(&r, 0, iface, name, type, domain, { _, _, _, err, _, host, port, txtLen, txt, ctx in
            guard let ctx else { return }
            let rc = Unmanaged<ResolveContext>.fromOpaque(ctx).takeUnretainedValue()
            guard err == kDNSServiceErr_NoError, let host, let browser = rc.browser else { return }
            var version: Int?
            if let txt {
                var len: UInt8 = 0
                if let p = TXTRecordGetValuePtr(txtLen, txt, "version", &len) {
                    version = Int(String(decoding: UnsafeRawBufferPointer(start: p, count: Int(len)), as: UTF8.self))
                }
            }
            var h = String(cString: host)
            if h.hasSuffix(".") { h.removeLast() }
            browser.onFound(FoundHub(name: rc.name, host: h, port: Int(UInt16(bigEndian: port)), version: version))
        }, box)
        guard err == kDNSServiceErr_NoError, let r else {
            Unmanaged<ResolveContext>.fromOpaque(box).release()
            return
        }
        DNSServiceSetDispatchQueue(r, bonjourQueue)
        resolves[name] = r
        // The context lives until the browser stops (a few bytes per hub seen).
        contexts.append(box)
    }

    private var contexts: [UnsafeMutableRawPointer] = []
}

private final class ResolveContext {
    weak var browser: BonjourBrowser?
    let name: String
    init(browser: BonjourBrowser, name: String) {
        self.browser = browser
        self.name = name
    }
}
