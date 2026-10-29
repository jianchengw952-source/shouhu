# 守护 (AuraSign Pro)

专为 **Dopamine (v3.0.12)** 与 **Relaxin (v0.5.6)** 打造的 iOS 液态玻璃全自动 7 天真证书续签、防掉签关机强拦截与免 VPN 直连软件源工坊。

## ✨ 特性一览
1. **重启守护 (AuraSignShield)**：拦截关机掉签行为，提供 1.5 秒极速真证书续签与安全重启。
2. **后台守护进程 (aurasignd)**：支持电量低于 5% 紧急抢救续签与定时静默续签，Jetsam 256MB 防杀。
3. **桌面控制中心 (AuraSignPro.app)**：液态玻璃视觉风格，支持直连苹果服务器完成免费 7 天开发者证书签名。
4. **双架构支持**：原生支持 Dopamine (rootless, arm64) 与 Relaxin (roothide, arm64e)。

## 🔨 编译构建
本项目已配置 GitHub Actions 自动化构建，每次 push 将自动在 macOS 虚拟环境中调用 RootHide Theos 编译生成双架构 `.deb` 安装包。
