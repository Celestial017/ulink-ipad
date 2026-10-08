import Foundation
import AVFoundation
import VideoToolbox

/// U-Link client: listens on a TCP port, parses the U-Link packet protocol
/// (see docs/protocol.md), rebuilds HEVC sample buffers and hands them to the
/// AVSampleBufferDisplayLayer for immediate presentation.
final class StreamClient {

    enum Pkt: UInt8 {
        case video = 1
        case config = 2
        case ping = 3
        case quality = 4
    }

    let port: UInt16

    weak var displayLayer: AVSampleBufferDisplayLayer?
    var onStatus: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    private let workQueue = DispatchQueue(label: "ulink.client")
    private var running = true
    private var listenFd: Int32 = -1
    private var connFd: Int32 = -1

    // stats
    private var windowFrames = 0
    private var windowBytes = 0
    private var windowStart = CFAbsoluteTimeGetCurrent()
    private var lastFps = 0.0
    private var lastMbps = 0.0
    private var rttMs = -1.0

    // HEVC parameter sets / format
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var formatDesc: CMFormatDescription?
    private var videoInfo = ""

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        workQueue.async { [weak self] in self?.runLoop() }
    }

    func stop() {
        running = false
        if connFd >= 0 { close(connFd); connFd = -1 }
        if listenFd >= 0 { close(listenFd); listenFd = -1 }
    }

    // MARK: - socket loop

    private func runLoop() {
        listenFd = makeListener()
        guard listenFd >= 0 else {
            DispatchQueue.main.async { self.onStatus?("监听端口失败 (\(self.port))") }
            return
        }
        while running {
            let c = accept(listenFd, nil, nil)
            if c < 0 {
                if !running { break }
                continue
            }
            connFd = c
            tuneSocket(c)
            formatDesc = nil
            videoInfo = ""
            DispatchQueue.main.async { self.onConnected?() }
            readLoop(c)
            close(c)
            connFd = -1
            DispatchQueue.main.async { self.onDisconnected?() }
        }
    }

    private func makeListener() -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return -1 }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let st = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if st != 0 { close(fd); return -1 }
        if listen(fd, 1) != 0 { close(fd); return -1 }
        return fd
    }

    private func tuneSocket(_ fd: Int32) {
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        var rcvbuf: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))
    }

    private func readLoop(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 1 << 18)
        var acc = Data()
        while running {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            acc.append(buf, count: n)
            var consumed = true
            while consumed {
                consumed = false
                guard acc.count >= 5 else { break }
                let head = [UInt8](acc.prefix(5))
                let len = UInt32(head[1]) | (UInt32(head[2]) << 8) | (UInt32(head[3]) << 16) | (UInt32(head[4]) << 24)
                guard acc.count >= 5 + Int(len) else { break }
                let payload = acc.subdata(in: (acc.startIndex + 5)..<(acc.startIndex + 5 + Int(len)))
                acc.removeFirst(5 + Int(len))
                handle(type: head[0], payload: payload)
                consumed = true
            }
        }
    }

    private func send(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var off = 0
            while off < data.count {
                let w = write(fd, base.advanced(by: off), data.count - off)
                if w <= 0 { break }
                off += w
            }
        }
    }

    // MARK: - packet handling

    private func handle(type: UInt8, payload: Data) {
        switch Pkt(rawValue: type) {
        case .video:
            windowFrames += 1
            windowBytes += payload.count
            processAccessUnit(payload)
        case .ping:
            guard payload.count >= 8 else { break }
            var sent: UInt64 = 0
            for i in 0..<8 { sent |= UInt64(payload[payload.startIndex + i]) << (8 * i) }
            let nowUs = DispatchTime.now().uptimeNanoseconds / 1000
            rttMs = Double(nowUs &- sent) / 1000.0
            // echo verbatim
            var out = Data([type])
            let l = UInt32(payload.count)
            out.append(contentsOf: [UInt8(l & 0xFF), UInt8((l >> 8) & 0xFF), UInt8((l >> 16) & 0xFF), UInt8((l >> 24) & 0xFF)])
            out.append(payload)
            send(connFd, out)
        case .config:
            if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                let w = obj["w"] as? Int ?? 0
                let h = obj["h"] as? Int ?? 0
                let fps = obj["fps"] as? Int ?? 0
                videoInfo = "\(w)x\(h)@\(fps)"
                pushStatus()
            }
        default:
            break
        }
        maybeEmitStats()
    }

    // MARK: - HEVC handling

    static func splitNALs(_ data: Data) -> [Data] {
        var out: [Data] = []
        let bytes = [UInt8](data)
        var i = 0
        var start = -1
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                if start >= 0 && i > start { out.append(Data(bytes[start..<i])) }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0 && start < bytes.count { out.append(Data(bytes[start...])) }
        return out
    }

    private func processAccessUnit(_ data: Data) {
        let nals = Self.splitNALs(data)
        var gotParams = false
        var hasVCL = false
        for nal in nals {
            guard let b0 = nal.first else { continue }
            let t = (b0 >> 1) & 0x3F
            switch t {
            case 32: vps = nal; gotParams = true
            case 33: sps = nal; gotParams = true
            case 34: pps = nal; gotParams = true
            case 0...31: hasVCL = true
            default: break
            }
        }
        if gotParams || formatDesc == nil { rebuildFormatDesc() }
        guard hasVCL, let fmt = formatDesc else { return }

        var avcc = Data()
        for nal in nals {
            guard let b0 = nal.first else { continue }
            let t = (b0 >> 1) & 0x3F
            if t == 35 { continue } // skip AUD
            var l = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &l) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        guard avcc.count > 0 else { return }
        makeSampleBuffer(avcc, formatDesc: fmt)
    }

    private func rebuildFormatDesc() {
        guard let vps, let sps, let pps else { return }
        var fmt: CMFormatDescription?
        vps.withUnsafeBytes { (v: UnsafeRawBufferPointer) in
            sps.withUnsafeBytes { (s: UnsafeRawBufferPointer) in
                pps.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                    guard let vb = v.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let sb = s.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let pb = p.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    let ptrs: [UnsafePointer<UInt8>] = [vb, sb, pb]
                    let sizes: [Int] = [v.count, s.count, p.count]
                    let st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: ptrs,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &fmt)
                    if st != noErr { fmt = nil }
                }
            }
        }
        formatDesc = fmt
    }

    private func makeSampleBuffer(_ avcc: Data, formatDesc: CMFormatDescription) {
        var blockBuffer: CMBlockBuffer?
        let count = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count, flags: 0,
            blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
            let bb = blockBuffer else { return }
        let st = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb,
                                          offsetIntoDestination: 0, dataLength: count)
        }
        guard st == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = count
        let cs = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: formatDesc,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard cs == noErr, let sb = sampleBuffer else { return }
        CMSetAttachment(sb, key: kCMSampleAttachmentKey_DisplayImmediately,
                        value: kCFBooleanTrue, attachmentMode: .shouldPropagate)

        DispatchQueue.main.async { [weak self] in
            guard let layer = self?.displayLayer else { return }
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sb)
        }
    }

    // MARK: - stats

    private func maybeEmitStats() {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = now - windowStart
        guard dt >= 1.0 else { return }
        lastFps = Double(windowFrames) / dt
        lastMbps = Double(windowBytes) * 8.0 / dt / 1_000_000.0
        windowFrames = 0
        windowBytes = 0
        windowStart = now

        // ping the PC every second
        let us = DispatchTime.now().uptimeNanoseconds / 1000
        var out = Data([Pkt.ping.rawValue, 8, 0, 0, 0])
        var v = us
        withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
        send(connFd, out)

        pushStatus()
    }

    private func pushStatus() {
        let text: String
        if videoInfo.isEmpty {
            text = String(format: "已连接 · 等待画面…")
        } else {
            text = String(format: "%@ · %.0f fps · %.1f Mbps · RTT %.0f ms", videoInfo, lastFps, lastMbps, max(rttMs, 0))
        }
        DispatchQueue.main.async { self.onStatus?(text) }
    }
}
