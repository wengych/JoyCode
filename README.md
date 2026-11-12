# JoyCode

<img src="Resources/AppIcon-master.png" alt="JoyCode 图标" width="96">

用 Xbox 手柄在 macOS 上控制 AI Agent：切换应用、开始和结束听写、检查后提交草稿、切换会话。

JoyCode 使用 Swift、GameController 和 Accessibility，直接读取手柄输入，无需额外的键盘映射软件或 API Key。默认使用 Agent 原生听写，也可选择 Typeless。

## 当前状态

**0.3.15 Early Preview · build 27**。电量进度改为显示在原手柄图标底部，保持原有宽度；未知或断连时保留原图标，不再显示问号。原生 GameController 未提供有效读数时，使用蓝牙系统报告后备读取。

215 项测试、单图标渲染样图及安装包构建、签名、SHA-256 校验通过，测试覆盖后台读取的单任务、取消和重试。实机已识别 Xbox Wireless Controller，显示“约 100% · 充电状态未知”，来源为 macOS 蓝牙报告；设置页的同一图标组件进度线正常。远端构建与发布结果见 [Actions](https://github.com/wengych/JoyCode/actions)。

- **Codex 原生听写在 0.3.12 已实测：**X 开始／X 结束、X 开始／B 取消、LB／RB 切换及再次开始；取消与切换连续两轮通过。这不是当前版本的重新验收。
- **Codex 右摇杆滚动异常：**最新实体测试失败，尚未修复。
- **Codex A 提交尚未确认：**最新组合测试反馈只说明滚动失败，不能视为提交已通过。
- Claude 的语音、单次提交、方向键和滚动有早期版本成功记录，尚未完成当前版本全键复测。

详见 [更新记录](CHANGELOG.md) 和 [开发与验证历史](docs/DEVELOPMENT-HISTORY.md)。

## 环境与启动

需要 macOS 14 或更新版本、Xbox 手柄及支持的桌面客户端。目前主要在 Apple Silicon 上验证。

- Claude Desktop／Claude Code：`com.anthropic.claudefordesktop`。
- ChatGPT／Codex：当前适配的客户端 Bundle ID 为 `com.openai.codex`，不代表所有 ChatGPT 桌面或网页版均兼容。
- 使用原生听写时，目标客户端须已有可用的听写入口。

1. 打开 `JoyCode.app`，连接手柄。应用初始处于诊断模式，仅显示最近输入。
2. 在系统设置 → 隐私与安全性 → 辅助功能（部分系统称“设备控制与数据访问”）中允许 JoyCode，以便聚焦输入框和操作目标控件。
3. 停止其他手柄映射软件；已有 InputConfig 用户可使用“退出 InputConfig 并接管手柄”。
4. 选择“Agent 原生听写”，启用控制并隐藏设置窗口。
5. 用 LB／RB 返回目标应用，再用 X 开始和结束听写。先检查生成的草稿，再按 A。

分发包使用本地 **ad-hoc 签名，未经 Apple notarization**，不是 Developer ID 签名的正式发行包。重新构建后可能需要刷新辅助功能授权。

## 手柄电量

菜单栏保持单个 18 pt 手柄图标，在同一图标底部以 16 × 2 pt 进度线表示有效电量，不增加第二个电池图标或菜单栏宽度。电量未知或手柄断连时维持原手柄图标，无问号。详细电量、充电状态及低电量提示放在菜单文字和设置窗口；低电量条件仍为不高于 20%、未充电且非已充满状态。

原生 GameController 每 30 秒刷新，有效读数优先；原生读数未知时，每 60 秒在后台读取蓝牙系统报告。仅当 GameController 和蓝牙报告均能唯一匹配已连接的 Xbox 手柄时采用后备读数，失败或有歧义仍显示未知。暂停遥控后也会刷新，菜单会区分读数来源。

未知不会被当作 0%，但蓝牙报告明确提供的有效 0% 可以显示。百分比是系统／手柄上报的估计值；100% 不用于推断正在充电。0.3.15 实机已显示蓝牙来源的约 100%，充电状态仍为未知；没有验收真实充电变化。菜单栏单槽布局经过代码和样图验证，实机界面检查覆盖的是设置页使用的同一图标组件，不是菜单栏截图验收。

## 按键

- **LB：**激活 Claude 并聚焦输入框。
- **RB：**激活 Codex 当前窗口，保留其输入焦点。
- **X：**在当前支持的 Agent 窗口内开始听写，再按一次结束；不会自动拉起其他 Agent。
- **A：**草稿稳定后提交一次，遵循当前 `Send`／`Queue`／`Steer` 模式；不触发 `Stop`／`Resume` 或权限审批。目标变化时先提示检查。
- **B：**取消 JoyCode 发起且仍在录音的听写。Codex 使用原生取消按钮，Claude 使用定向 Esc。**进入转写阶段后，需在 Agent 内手动取消。**
- **方向键 ↑／↓：**切换当前应用的会话。Claude Code 使用会话菜单；Codex 使用上一／下一侧栏项目，混合侧栏中也可能选中 Page 或附件。
- **右摇杆 ↑／↓：**尝试滚动当前回复区，回中停止。**Codex 当前异常；滚动也可能移动真实鼠标指针。**

不绑定主页键、系统菜单键及摇杆左右方向；暂不提供按住说话。

普通动作捕获当前应用、进程和窗口，并在执行时复核。切窗或目标不明会停止操作；只有肩键和明确的激活入口能主动切换窗口。录音／转写期间锁定目标；状态不明时，仅在原窗口只读确认空闲后恢复，不会自动重录或发送。手动复位不负责停止 Agent 的录音。

同一目标、同一草稿的提交尝试会保留记录，防止结果未知时重复提交；切到其他 Agent 不会清除记录，观察到同一编辑器内容改变或清空后才释放。客户端更新可能改变可访问性结构，遇到未知控件时应用会拒绝操作。

## Typeless（可选）

可设置全局语音来源及按应用覆盖。选择 Typeless 后需保持其运行，并把 JoyCode 快捷键设为与 Typeless 一致；初始值为左 Option + 反引号。支持录制左右修饰键和 Fn，保存设置只修改 JoyCode。

录音开始时固定后端和快捷键，中途不会自动回退。Typeless 浮层若夺取前台，需手动返回原 Agent 窗口再操作；取消后可能需要再次 B 确认复位。

## 构建与打包

需要 Xcode／Swift 工具链，无第三方 Swift 包依赖。在仓库根目录运行：

```bash
bash test.sh
bash build.sh
open "dist/JoyCode.app"
```

生成发布压缩包和校验文件：

```bash
bash package-release.sh
(cd dist && shasum -a 256 -c SHA256SUMS)
```

打包脚本会重新构建；默认输出 `dist/JoyCode-0.3.15-build27-macos-arm64.zip` 和 `dist/SHA256SUMS`，架构名按实际二进制确定。构建缓存位于 `.build-work/`。可通过 `JOYCODE_BUILD_ROOT`、`JOYCODE_DIST_DIR` 等环境变量覆盖路径，相对值均按仓库根目录解析；完整选项见 [script-env.sh](script-env.sh)。

图标源文件为 [Resources/AppIcon-master.png](Resources/AppIcon-master.png)。修改后运行 `bash make-icon.sh` 更新 ICNS；正常构建保留已有图标。

## 本地数据与代码

为兼容早期配置，Bundle ID／UserDefaults 域保持 `local.weng.XboxAgentRemote`，内部可执行文件名保持 `XboxAgentRemote`。配置保存在本机，草稿备份只保留在内存中。

JoyCode 不采集或上传语音；语音由所选 Agent 或 Typeless 处理。诊断记录动作与窗口身份等元数据，不记录草稿、转写或录音内容。快捷键录制仅在设置窗口获得焦点时工作。

- [Sources/XboxAgentRemote](Sources/XboxAgentRemote)：应用界面、手柄输入、协调器与 Accessibility 适配。
- [Sources/RemoteCore](Sources/RemoteCore)：状态、目标约束、控件语义与滚动计算。
- [Tests/RemoteCoreTests](Tests/RemoteCoreTests)：核心回归测试。
