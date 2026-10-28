# AdSkipVpn (HarmonyOS NEXT)

基于 **HarmonyOS NEXT (API 12+)** 的开屏广告自动跳过与本地 VPN 域名拦截工具。

## ✨ 核心功能

### 1. ⚡ 开屏自动跳过 (`Tab 1`)
- **无障碍节点极速巡检**：实时检测当前前台应用无障碍布局树中的可见开屏跳过控件（`跳过`、`跳过广告`、`关闭广告`、`Skip` 等），精准过滤右侧区域有效按钮并自动完成触控点击。
- **淡入期连续复检**：针对开屏广告淡入初期首次点击尚未响应的场景，内置 `100ms` 极速复检机制，确保一次打开稳定跳过。
- **NAPI 本地状态桥接 (`libadskip_bridge.so`)**：应用内一键切换自动跳过运行/暂停状态，实时同步已自动跳过次数与历史跳过日志。
- **无后台卡片常驻**：应用退至后台后自动销毁 UI 实例并从系统多任务卡片中移除，后台守护进程保持独立轻量运行。

### 2. 🌐 VPN 域名过滤 (`Tab 2`)
- **本地 TUN 虚拟网卡 (`VpnExtensionAbility`)**：在设备本地建立虚拟 DNS (`10.88.0.1`) 拦截通道，不依赖任何外部代理服务器。
- **DNS 黑名单伪造响应 + HTTPDNS VIP 路由阻断**：
  - 命中主流广告联盟域名黑名单时，直接在本地返回 `0.0.0.0`，毫秒级阻断广告资源加载；
  - 路由接管常见 HTTPDNS VIP 网段，防止应用绕过系统 DNS 下发广告，自动触发降级回标准 DNS。
- **自定义规则热加载 & 实时抓包日志**：支持在应用内动态添加自定义拦截域名并热同步至 VPN 引擎。

---

## 📂 工程目录结构

```text
adskipvpn/
├── AppScope/                                 # 全局应用配置与图标资源
├── entry/
│   └── src/main/
│       ├── cpp/                              # NAPI 本地通信桥接 (libadskip_bridge.so)
│       ├── ets/
│       │   ├── accessibilityability/         # 无障碍扩展 Ability (AdSkipAccessibilityAbility)
│       │   ├── entryability/                 # 主界面 UIAbility (退后台自动移除多任务卡片)
│       │   ├── pages/Index.ets               # 双 Tab 主界面 (开屏自动跳过 + VPN 域名过滤)
│       │   ├── vpn/                          # 本地 DNS 解析器、广告域名规则库与 VPN 引擎
│       │   └── vpnability/                   # VPN 扩展 Ability (AdBlockVpnAbility)
│       └── resources/rawfile/
│           └── adskip_daemon.sh              # 本机常驻开屏跳过守护脚本
└── activate_offline_skip.sh                  # 一键推送并激活本机脱机开屏跳过守护服务脚本
```

---

## 🚀 快速开始

1. 使用 **DevEco Studio** 打开本工程目录 `adskipvpn`。
2. 进入 `File -> Project Structure -> Signing Configs`，勾选 **Automatically generate signature** 自动生成调试签名。
3. 连接 HarmonyOS NEXT 真机，编译并运行 `entry` 模块安装应用。
4. 在电脑终端执行一键激活脚本启动本机守护服务（激活后可拔掉数据线独立运行）：
   ```bash
   ./activate_offline_skip.sh
   ```
