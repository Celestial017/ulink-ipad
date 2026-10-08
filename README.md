# U-Link · iPad 接收端

PC 画面以 120Hz 串流到 iPad 的接收 App（自研，含 UP 主协议 U-Link v0.1，见 `../docs/protocol.md`）。

## 构建（GitHub Actions，无需 Mac）

`.github/workflows/build.yml`：push 到 `main` 即自动构建**未签名 ipa**。两个获取途径：

1. Actions 产物：`UlinkClient-unsigned-ipa`
2. `builds` 分支里的 `UlinkClient-unsigned.ipa`（备用，公开仓库可直接匿名拉取）

## 安装（Sideloadly，Windows）

1. iPad 用线连接电脑，点"信任此电脑"
2. 打开 Sideloadly，把 ipa 拖进去，输入 Apple ID（免费账号即可）
3. 点 Start，按提示在 iPad「设置 → 通用 → VPN与设备管理」信任开发者
4. 免费签名 7 天过期：重新 Start 一次即续签（App 数据保留）

## 使用

1. iPad 打开 U-Link，屏幕显示本机地址，例如 `192.168.1.23:52700`
2. 电脑上运行（在项目根目录）：
   ```
   python pc/sender.py --host 192.168.1.23 --port 52700
   ```
3. 串流中轻点屏幕显示状态条（fps / Mbps / RTT）；想彻底断开就退出 App
