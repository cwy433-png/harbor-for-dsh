# Harbor for DeepSeek Harness

一个小巧的 macOS app，把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
放进真正的窗口里，有自己的程序坞图标，并且——这才是重点——**能真正退出**。

> **非官方项目。** 与 DeepSeek 无关联、未获其背书、也不由其提供支持。
> DeepSeek Harness 是 DeepSeek 以 MIT 协议发布的软件，本项目只是它的第三方启动器。
> 本 app 的问题与他们无关，请不要把相关 issue 提到他们的仓库。

[English](README.md)

## 为什么需要它

`dsh web` 会启动一个本地服务器并打印网址。关掉浏览器标签页**并不会**停掉服务器——
它会一直跑下去，直到你把它找出来杀掉。Harbor 给 harness 补上了应用程序该有的生命周期：
Cmd+Q 会停掉服务器以及它派生的每一个进程；如果 app 被强制退出，下次启动会先把上次
留下的孤儿进程收拾干净。

## 安装

从 release 页下载 `.dmg`，打开它，把 app 拖到旁边的「应用程序」文件夹上。

**第一次打开时 macOS 会拒绝。** 因为这个 app 没有做公证（需要付费的 Apple 开发者账号）。
绕过方法：

1. 双击 app，macOS 提示无法打开。
2. 打开 **系统设置 → 隐私与安全性**。
3. 滚到底部，在关于 Harbor 的提示旁点 **仍要打开**。
4. 确认。

只需做这一次。如果你不接受这个代价，可以自己构建（见[构建](#构建)）——
本地构建出来的 app 不会被 macOS 质疑。

## 首次启动

Harbor 需要一个 Node 运行时和 harness 本体。**下载任何东西之前，它会先明确告诉你要下什么。**

- **Node** —— 如果你的 Mac 上已经有 harness 能用的版本，Harbor 直接使用，**不下载任何东西**。
  只有在完全找不到时，才从 nodejs.org 官方下载，并用官方公布的校验和验证完整性。
- **DeepSeek Harness** —— 从 npm registry 安装到 Harbor 自己的目录，约 350MB，需要几分钟。

不会安装任何系统级的东西，也不会修改你 Mac 上已有的任何内容。

装好后，在 app 内打开 **设置 → 模型**，填入你的 DeepSeek API key。
它以只写方式存放在 `~/.dsh/.credentials.yaml`，界面永远不会拿回明文。

## 更新 harness

Harbor 会在启动时以及每隔几小时自动检查新版本，发现了就告诉你。**但它绝不会自作主张安装**——
见[刻意不做的事](#harbor-刻意不做的事)。用 **Harness → Check Automatically** 可以关掉检查。

DeepSeek Harness 是开发者预览版，明确声明版本间可能破坏兼容性，所以更新是**分阶段**的，
不是就地覆盖：

1. 新版本下载到自己独立的目录，当前能用的那份完全不动。
2. 先把 `~/.dsh` 里的会话和设置复制一份。
3. 只有新版本完整装好之后，才通过切换一个符号链接让它生效。

因此更新失败或被取消，原来能用的版本依然能用。
**Harness → Roll Back to Previous Version…** 可以退回上一版。

有一点需要理解：harness 的会话数据库 schema 只会向前演进，且会拒绝它不认识的格式。
如果新版本已经写过 `~/.dsh`，那么只把代码回滚，可能导致旧版本读不了这些数据。
这正是要先做快照的原因——快照在 **Harness → Reveal App Support Folder** 的 `snapshots` 里。

## 使用本地 checkout

**Harness → Use Local Checkout…** 让 Harbor 指向你自己编译的 `deepseek-harness` 工作副本。
Harbor 只负责起停，**不会**替你跑 `git pull` 或 `pnpm build`。
**Use Released Version** 切回发布版。

## Harbor 刻意不做的事

- **绝不接管不是自己启动的服务器。** 如果 3080 端口已被占用，Harbor 会拒绝启动并说明原因。
  接管别人的服务器，意味着要么杀掉你在终端里启动的进程，要么在退出时默默不管它——
  而「干净地退出」正是这个 app 存在的全部理由。
- **绝不安装系统级的东西**，也绝不往自己的 app bundle 内部写任何文件。
- **绝不擅自安装更新。** 它只告诉你有新版本，装不装是你的决定。一个可能弄坏环境的预览版，
  不该在你正干活的时候自己装上。

## 关于版本号的一个提醒

**装某个具体版本，并不能锁定整棵依赖树。** harness 根包对它那六十多个子包用的是 `^` 范围，
npm 会把它们解析成同一条 `0.1.x` 线上的最新版——今天装 `0.1.0-rc.3`，得到的是它的启动器
配上新得多的内脏。这是包的发布方式决定的，**所有安装途径都一样，包括 `npx`**。

这正是本项目的回滚是「切回上一个已安装目录」而不是「重装上一个版本号」的原因：
那个目录里仍然是你当时实际在跑的那棵树，而今天重装同一个版本号已经复现不出它了。

## 构建

需要 Xcode 命令行工具（`xcode-select --install`）。除此之外别无依赖——
图标流水线和编译器都是 macOS 自带的。

```bash
./build.sh
```

产物在 `build/`，使用 ad-hoc 签名，足够在构建它的机器上运行。
加 `--dmg` 可以同时打包用于发布页的磁盘映像。

要发布一个不需要用户去「隐私与安全性」里点确认的版本：

```bash
./build.sh --sign "Developer ID Application: Your Name (TEAMID)" --notarize <profile>
```

公证配置用 `xcrun notarytool store-credentials` 创建一次即可。

## 文件位置

| | |
|---|---|
| harness 运行时、Node、快照、日志 | `~/Library/Application Support/Harbor for DeepSeek Harness/` |
| 会话、设置、凭据 | `~/.dsh/`（与终端里的 `dsh` 共用） |

Harbor 永远不会删除 `~/.dsh`。删掉 app 和它的 Application Support 目录，你的会话依然完好。

## 许可证

MIT，见 [LICENSE](LICENSE)。
