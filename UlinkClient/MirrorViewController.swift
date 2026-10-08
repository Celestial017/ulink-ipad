import UIKit
import AVFoundation

/// U-Link mirror UI v1.0 (rewrite).
///
/// Explicit connection state machine driven by StreamClient callbacks:
///   .listening     -> banner "等待电脑连接…"
///   .connected     -> banner hidden, video plays
///   .stalled       -> banner "信号中断…" (link alive but no data)
///   .disconnected  -> banner "连接断开，等待重连…"
///
/// On foreground: if the client's accept loop has died for any reason, it is
/// recreated from scratch (self-healing after suspension / OOM kill / crash).
final class MirrorViewController: UIViewController {

    private enum State {
        case listening
        case connected
        case stalled
        case disconnected
    }

    private var videoLayer = CALayer()
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private var client: StreamClient?
    private var displayLink: CADisplayLink?
    private var hideWork: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoLayer.contentsGravity = .resizeAspect
        videoLayer.backgroundColor = UIColor.black.cgColor
        videoLayer.frame = view.bounds
        view.layer.addSublayer(videoLayer)

        statusLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.92)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.layer.backgroundColor = UIColor.black.withAlphaComponent(0.45).cgColor
        statusLabel.layer.cornerRadius = 8
        statusLabel.layer.masksToBounds = true
        statusLabel.alpha = 0
        view.addSubview(statusLabel)

        hintLabel.font = UIFont.systemFont(ofSize: 15, weight: .regular)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        view.addSubview(hintLabel)

        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showStatusBriefly)))

        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)

        startClient()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        videoLayer.frame = view.bounds
        hintLabel.frame = view.bounds
        let w = min(view.bounds.width - 48, 560)
        statusLabel.frame = CGRect(x: (view.bounds.width - w) / 2, y: 24, width: w, height: 0)
        statusLabel.sizeToFit()
        statusLabel.frame = CGRect(x: (view.bounds.width - w) / 2, y: 24, width: w,
                                   height: statusLabel.frame.height + 14)
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    private func startClient() {
        // only ever replaces a dead client (or builds the first one)
        if let old = client {
            guard !old.isAlive else { return }
            old.stop()
        }
        client = nil

        showBanner(.listening)

        let c = StreamClient(port: 52700)
        c.videoLayer = videoLayer
        c.onListening = { [weak self] in self?.showBanner(.listening) }
        c.onConnected = { [weak self] in
            self?.showBanner(nil)
            self?.showStatusBriefly()
        }
        c.onStalled = { [weak self] in self?.showBanner(.stalled) }
        c.onDisconnected = { [weak self] in self?.showBanner(.disconnected) }
        c.onStatus = { [weak self] text in
            guard let self else { return }
            self.statusLabel.text = "  " + text + "  "
            self.showStatusBriefly()
        }
        c.start()
        client = c

        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(onDisplayTick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func onDisplayTick() {
        client?.swapLatestSurface(into: videoLayer)
    }

    private func showBanner(_ state: State?) {
        let ip = NetworkInfo.wifiAddress() ?? "未知"
        switch state {
        case nil:
            hintLabel.isHidden = true
        case .listening:
            hintLabel.text = "U-Link\n\n等待电脑连接…\niPad 地址 \(ip):52700\n\n轻点屏幕查看状态"
            hintLabel.isHidden = false
        case .connected:
            hintLabel.isHidden = true
        case .stalled:
            hintLabel.text = "U-Link\n\n信号中断…\n正在等待数据 / 自动恢复\n\n轻点屏幕查看状态"
            hintLabel.isHidden = false
        case .disconnected:
            hintLabel.text = "U-Link\n\n连接断开，等待重连…\n电脑端请重跑 启动投屏.bat\n\n轻点屏幕查看状态"
            hintLabel.isHidden = false
        }
        if state != nil { statusLabel.alpha = 0 }
    }

    @objc private func showStatusBriefly() {
        hideWork?.cancel()
        UIView.animate(withDuration: 0.15) { self.statusLabel.alpha = 1 }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.hintLabel.isHidden {
                UIView.animate(withDuration: 0.4) { self.statusLabel.alpha = 0 }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    @objc private func willEnterForeground() {
        UIApplication.shared.isIdleTimerDisabled = true
        // self-heal: resurrect the receiver if its accept loop died while
        // backgrounded/suspended (OOM kill, crash, iOS socket teardown, ...)
        startClient()
    }

    @objc private func didEnterBackground() {
        // stream pauses while suspended; willEnterForeground heals/resumes
    }
}
