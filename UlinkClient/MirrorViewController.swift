import UIKit
import AVFoundation

final class MirrorViewController: UIViewController {

    private var displayLayer = AVSampleBufferDisplayLayer()
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private var client: StreamClient?
    private var hideWork: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.frame = view.bounds
        view.layer.addSublayer(displayLayer)

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
        displayLayer.frame = view.bounds
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
        refreshHint()
        let client = StreamClient(port: 52700)
        client.displayLayer = displayLayer
        client.onConnected = { [weak self] in
            self?.hintLabel.isHidden = true
            self?.showStatusBriefly()
        }
        client.onDisconnected = { [weak self] in
            guard let self else { return }
            self.hintLabel.isHidden = false
            self.refreshHint(disconnected: true)
        }
        client.onStatus = { [weak self] text in
            guard let self else { return }
            self.statusLabel.text = "  " + text + "  "
            self.showStatusBriefly()
        }
        client.onRebuildLayer = { [weak self] in
            guard let self else { return }
            let newLayer = AVSampleBufferDisplayLayer()
            newLayer.videoGravity = .resizeAspect
            newLayer.backgroundColor = UIColor.black.cgColor
            newLayer.frame = self.view.bounds
            self.displayLayer.removeFromSuperlayer()
            self.view.layer.addSublayer(newLayer)
            self.displayLayer = newLayer
            self.client?.replaceLayer(newLayer)
        }
        client.start()
        self.client = client
    }

    private func refreshHint(disconnected: Bool = false) {
        let ip = NetworkInfo.wifiAddress() ?? "未知"
        let head = disconnected ? "连接断开，等待重连…" : "等待电脑连接…"
        hintLabel.text = "U-Link\n\n\(head)\niPad 地址 \(ip):52700\n\n轻点屏幕查看状态"
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
        displayLayer.flush()
    }

    @objc private func didEnterBackground() {
        displayLayer.flush()
    }
}
