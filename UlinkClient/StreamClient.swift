import Foundation
import AVFoundation
import VideoToolbox
import CoreVideo
import Darwin

/// U-Link client v0.3: explicit VideoToolbox HEVC decode into CVPixelBuffers,
/// then present decoded frames through AVSampleBufferDisplayLayer (uncompressed path).
/// All stages are counted and reported back to the PC as telemetry.
final class StreamClient {

    enum Pkt: UInt8 {
        case video = 1
        case config = 2
        case ping = 3
        case quality = 4
    }

    let port: UInt16

    weak var videoLayer: CALayer?
    var onStatus: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    private let workQueue = DispatchQueue(label: "ulink.client")
    private var running = true
    private var listenFd: Int32 = -1
    private var connFd: Int32 = -1

    // stats (window) + cumulative telemetry
    private var windowFrames = 0
    private var windowBytes = 0
    private var windowStart = CFAbsoluteTimeGetCurrent()
    private var lastFps = 0.0
    private var lastMbps = 0.0
    private var rttMs = -1.0

    private var totalFrames = 0
    private var enqOk = 0
    private var enqSkip = 0
    private var layerFailures = 0
    private var readTicks = 0
    private var decOk = 0
    private var decErr = 0
    private var dropped = 0
    private var presented = 0
    private var shown = 0
    private let surfaceLock = NSLock()
    private var latestSurface: IOSurface?
    private let inFlightLock = NSLock()
    private var inFlight = 0

    /// Called from the CADisplayLink on the main thread: paint the newest decoded frame, drop stale ones.
    func swapLatestSurface(into layer: CALayer) {
        surfaceLock.lock()
        let s = latestSurface
        latestSurface = nil
        surfaceLock.unlock()
        if let s {
            layer.contents = s
            shown += 1
        }
    }

    // HEVC params / decoding
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var formatDesc: CMFormatDescription?
    private var session: VTDecompressionSession?
    private var lastVPS: Data?
    private var lastSPS: Data?
    private var lastPPS: Data?
    private var videoInfo = ""
    private var diagSkipDecode = false
    private var accCapacity = 0

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
            resetDecoder()
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
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let st = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if st != 0 { close(fd); return -1 }
        if listen(fd, 2) != 0 { close(fd); return -1 }
        return fd
    }

    private func tuneSocket(_ fd: Int32) {
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        var rcvbuf: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))
    }

    private func readLoop(_ fd: Int32) {
        // Flat byte buffer + one memmove per read chunk. Avoids Foundation.Data
        // removeFirst()/append churn that appeared to retain ~one frame per frame.
        var buf = [UInt8]()
        buf.reserveCapacity(1 << 21)
        var tmp = [UInt8](repeating: 0, count: 1 << 18)
        while running {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            readTicks += 1
            buf.append(contentsOf: tmp[0..<n])
            var pos = 0
            while buf.count - pos >= 5 {
                let len = UInt32(buf[pos + 1]) | (UInt32(buf[pos + 2]) << 8) | (UInt32(buf[pos + 3]) << 16) | (UInt32(buf[pos + 4]) << 24)
                guard buf.count - pos >= 5 + Int(len) else { break }
                let type = buf[pos]
                let payload = Data(buf[(pos + 5)..<(pos + 5 + Int(len))])
                pos += 5 + Int(len)
                handle(type: type, payload: payload)
            }
            if pos > 0 {
                buf.removeFirst(pos)
            }
            accCapacity = buf.capacity
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
            totalFrames += 1
            windowBytes += payload.count
            processAccessUnit(payload)
        case .ping:
            guard payload.count >= 12 else { break }
            let p = [UInt8](payload.prefix(4))
            if p == [0x55, 0x4C, 0x50, 0x47] {          // "ULPG": PC's ping -> echo exactly once
                var out = Data([type])
                let l = UInt32(payload.count)
                out.append(contentsOf: [UInt8(l & 0xFF), UInt8((l >> 8) & 0xFF), UInt8((l >> 16) & 0xFF), UInt8((l >> 24) & 0xFF)])
                out.append(payload)
                send(connFd, out)
            } else if p == [0x55, 0x4C, 0x41, 0x50] {   // "ULAP": our own ping returned -> measure RTT
                var sent: UInt64 = 0
                for i in 0..<8 { sent |= UInt64(payload[payload.startIndex + 4 + i]) << (8 * i) }
                let nowUs = DispatchTime.now().uptimeNanoseconds / 1000
                rttMs = Double(nowUs &- sent) / 1000.0
            }
            // anything else: ignore (prevents echo storms)
        case .config:
            if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                let w = obj["w"] as? Int ?? 0
                let h = obj["h"] as? Int ?? 0
                let fps = obj["fps"] as? Int ?? 0
                if let d = obj["diag"] as? Int { diagSkipDecode = (d == 1) }
                videoInfo = "\(w)x\(h)@\(fps)"
                pushStatus()
            }
        default:
            break
        }
        maybeEmitStats()
    }

    // MARK: - NAL handling

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
        guard let sb = makeCompressedSampleBuffer(avcc, formatDesc: fmt) else { return }
        decode(sb)
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
        let changed = (vps != lastVPS || sps != lastSPS || pps != lastPPS)
        lastVPS = vps
        lastSPS = sps
        lastPPS = pps
        if let f = fmt, session == nil || changed {
            // parameter sets changed (e.g. upstream encoder swap): rebuild the decoder session
            createDecoderSession(f)
        }
    }

    private func createDecoderSession(_ fmt: CMFormatDescription) {
        if let s = session {
            VTDecompressionSessionInvalidate(s)
            session = nil
        }
        let spec: [CFString: Any] = [kVTDecompressionPropertyKey_RealTime: kCFBooleanTrue as Any]
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: NSDictionary(),
        ]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                              formatDescription: fmt,
                                              decoderSpecification: spec as CFDictionary,
                                              imageBufferAttributes: attrs as CFDictionary,
                                              outputCallback: nil,
                                              decompressionSessionOut: &s)
        if st == noErr { session = s }
    }

    private func resetDecoder() {
        if let s = session {
            VTDecompressionSessionInvalidate(s)
            session = nil
        }
        formatDesc = nil
        videoInfo = ""
        inFlightLock.lock()
        inFlight = 0
        inFlightLock.unlock()
    }

    private func makeCompressedSampleBuffer(_ avcc: Data, formatDesc: CMFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let count = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count, flags: 0,
            blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
            let bb = blockBuffer else { return nil }
        let st = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb,
                                          offsetIntoDestination: 0, dataLength: count)
        }
        guard st == kCMBlockBufferNoErr else { return nil }
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var sampleSize = count
        let cs = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: formatDesc,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard cs == noErr else { return nil }
        return sampleBuffer
    }

    private func decode(_ sampleBuffer: CMSampleBuffer) {
        if diagSkipDecode {
            dropped += 1
            return
        }
        inFlightLock.lock()
        let busy = inFlight >= 3
        if !busy { inFlight += 1 }
        inFlightLock.unlock()
        if busy {
            dropped += 1
            return
        }
        guard let session else {
            dropped += 1
            inFlightLock.lock(); inFlight -= 1; inFlightLock.unlock()
            return
        }
        var flagsOut = VTDecodeInfoFlags()
        let st = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer,
            flags: [], infoFlagsOut: &flagsOut
        ) { [weak self] status, _flags, imageBuffer, pts, _duration in
            guard let self else { return }
            self.inFlightLock.lock()
            if self.inFlight > 0 { self.inFlight -= 1 }
            self.inFlightLock.unlock()
            if status != noErr || imageBuffer == nil {
                self.decErr += 1
                return
            }
            self.decOk += 1
            self.present(imageBuffer!, pts: pts)
        }
        if st != noErr {
            inFlightLock.lock(); inFlight -= 1; inFlightLock.unlock()
            decErr += 1
            // decoder wedged? try a fresh session on repeated failures
            if decErr > 20, decErr % 20 == 0, let f = formatDesc {
                if let s = self.session { VTDecompressionSessionInvalidate(s) }
                self.session = nil
                createDecoderSession(f)
            }
        }
    }

    private func present(_ imageBuffer: CVImageBuffer, pts: CMTime) {
        guard let ios = CVPixelBufferGetIOSurface(imageBuffer)?.takeUnretainedValue() else { return }
        surfaceLock.lock()
        latestSurface = ios
        surfaceLock.unlock()
        presented += 1
    }

    // MARK: - stats / telemetry

    private func maybeEmitStats() {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = now - windowStart
        guard dt >= 1.0 else { return }
        lastFps = Double(windowFrames) / dt
        lastMbps = Double(windowBytes) * 8.0 / dt / 1_000_000.0
        windowFrames = 0
        windowBytes = 0
        windowStart = now

        let us = DispatchTime.now().uptimeNanoseconds / 1000
        var out = Data([Pkt.ping.rawValue])
        let lp: UInt32 = 12
        out.append(contentsOf: [UInt8(lp & 0xFF), UInt8((lp >> 8) & 0xFF), UInt8((lp >> 16) & 0xFF), UInt8((lp >> 24) & 0xFF)])
        out.append(contentsOf: [0x55, 0x4C, 0x41, 0x50])  // "ULAP"
        var v = us
        withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
        send(connFd, out)

        pushStatus()

        let telem = String(format: "{\"fr\":%d,\"dec\":%d,\"derr\":%d,\"drp\":%d,\"pre\":%d,\"shown\":%d,\"rd\":%d,\"cap\":%d,\"memMB\":%.0f}",
                           totalFrames, decOk, decErr, dropped, presented, shown, readTicks, accCapacity, Self.rssMB())
        if let td = telem.data(using: .utf8) {
            var out4 = Data([Pkt.quality.rawValue])
            let l4 = UInt32(td.count)
            out4.append(contentsOf: [UInt8(l4 & 0xFF), UInt8((l4 >> 8) & 0xFF), UInt8((l4 >> 16) & 0xFF), UInt8((l4 >> 24) & 0xFF)])
            out4.append(td)
            send(connFd, out4)
        }
    }

    private func pushStatus() {
        let text: String
        if videoInfo.isEmpty {
            text = "已连接 · 等待画面…"
        } else {
            text = String(format: "%@ · %.0f fps · %.1f Mbps · RTT %.0f ms", videoInfo, lastFps, lastMbps, max(rttMs, 0))
        }
        DispatchQueue.main.async { self.onStatus?(text) }
    }

    private static func rssMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576.0 : -1
    }
}
