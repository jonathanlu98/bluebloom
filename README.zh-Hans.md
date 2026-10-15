<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Blue Bloom 图标">
</p>

<h1 align="center">Blue Bloom</h1>

<p align="center">为 Mac 带来高品质蓝牙音频</p>

<p align="center"><a href="README.md">English</a> · <b>简体中文</b></p>

Blue Bloom 是一款菜单栏 app，用耳机支持的最好编码把 Mac 的声音推到蓝牙耳机：**LDAC、aptX HD、aptX、AAC 或 SBC**。macOS 自己只会用 AAC 或 SBC。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/panel-dark.png">
    <img src="docs/images/panel-light.png" width="348" alt="Blue Bloom 菜单栏面板，正以 96 kHz / 24 位 LDAC 推流">
  </picture>
</p>

截图里的界面是英文；app 会按系统语言显示中文。

## 功能

- **更好的编码**：LDAC 最高 96 kHz / 24 位（330、660 或 990 kbps），aptX HD（24 位），aptX，最高 320 kbps 的 AAC，以及包括 SBC XQ（双声道，约 500 kbps）在内的 SBC。
- **自适应码率**：蓝牙链路拥堵时，LDAC、SBC、AAC 自动降码率，链路好转后再升回来。
- **采样率跟随音乐**：Apple Music 播放时尽量用曲目的采样率（在编码支持的范围内），其他时候跟随输出设备。
- **音量和按键**：Mac 的音量直接调耳机自己的功放（AVRCP 绝对音量），耳机上的播放、暂停、切歌按键控制 Mac。
- 菜单里显示耳机**电量**。
- **自动模式**：只有耳机支持比 macOS 更好的编码（LDAC 或 aptX）时才接管，否则留给 macOS。
- 界面支持英文、简体中文、繁体中文、日文、韩文、德文、法文、西班牙文。

## 系统要求

- Apple 芯片的 Mac，macOS 14.2 或更高版本。
- 在 macOS 27 上测试过。其他版本上，Blue Bloom 会先征得你同意再接管耳机。

## 工作原理

- Blue Bloom 直接与 macOS 的蓝牙守护进程通信，自己建立到耳机的 A2DP 通道，因此能自己选编码和码率。它同时占用免提和遥控通道，这样 macOS 不会把耳机切到通话模式，音量和按键也都经过 Blue Bloom。
- 它会添加一个名为 **Blue Bloom** 的虚拟音频设备，app 播放到这个设备的声音会被编码后推到耳机。
- 退出 Blue Bloom 或关掉它时，耳机会交还给 macOS。

## 限制

- Blue Bloom 连着耳机时，其他 app 不能使用耳机麦克风，包括通话、听写和录音。
- Blue Bloom 依赖 macOS 私有接口，系统更新可能让它失效。遇到这种情况，关掉或退出 Blue Bloom 即可。

## 安装

目前还没有签名的发行版，需要从源码构建。你需要 Xcode 26 或更高版本，以及 [Bazelisk](https://github.com/bazelbuild/bazelisk)（`brew install bazelisk`）。

```sh
git clone https://github.com/JBoomRadio/bluebloom.git
cd bluebloom
tools/install-app.sh
```

`install-app.sh` 会构建 app、安装到 `~/Applications` 并打开。第一次启动时：

1. 允许访问蓝牙。
2. 阅读首次说明。
3. 按提示安装 Blue Bloom 音频设备，需要输入一次管理员密码。

## 使用

- 点菜单栏的 Blue Bloom 图标：打开或关闭、选择耳机，在推流卡片里切换编码或音质。
- **设置**里有通用、编码、音频、设备、高级、关于几页。
- 遇到问题时，**设置 › 关于 › 复制诊断信息**会复制一份不含设备地址的报告；日志在 `~/Library/Logs/BlueBloom.log`。
- 想彻底移除，用**设置 › 高级 › 卸载 Blue Bloom…**：删除音频设备、登录项、设置和日志，再把 app 移到废纸篓。

另有一个命令行工具，主要供开发使用：

```sh
bazel build //CLI:bluebloom
bazel-bin/CLI/bluebloom list                 # 已配对的设备
bazel-bin/CLI/bluebloom probe "<设备名>"      # 耳机声明的编码
bazel-bin/CLI/bluebloom codectest            # 不用耳机，用每种编码编一段测试音
```

## 开发

```sh
bazel build //App:BlueBloom //CLI:bluebloom
bazel run //tools/codectest:sbc_roundtrip    # 另有 aac_roundtrip、ldac_roundtrip
```

界面文字用 String Catalog 做本地化。改了界面文字后运行 `zsh tools/i18n/update-strings.sh`，把翻译写进 `tools/i18n/translations/<语言>.json`，再运行 `python3 tools/i18n/apply-translations.py`。

## 许可证

Blue Bloom 以 [MIT 许可证](LICENSE)发布。其中包含的第三方代码各有自己的许可证（Apache 2.0 和 LGPL 2.1），详见 [`third_party/README.md`](third_party/README.md)。app 的**设置 › 关于**里有完整声明。

LDAC 是 Sony Corporation 的商标。aptX 是 Qualcomm Technologies, Inc. 的商标。Bluetooth 是 Bluetooth SIG, Inc. 的注册商标。其他名称归各自所有者。Blue Bloom 与上述公司没有关联，也未获其认可或认证，按原样提供，不做任何担保。
