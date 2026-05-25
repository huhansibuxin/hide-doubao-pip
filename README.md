# HideDoubaoPiP

隐藏豆包输入法画中画悬浮窗的 SpringBoard tweak，适用于 iOS 16 Dopamine rootless 越狱。

## 功能

- 仅注入 SpringBoard，只处理 `SBPictureInPictureWindow`
- 优先通过 bundle ID `com.bytedance.ios.doubaoime` 识别豆包 PiP
- bundle/process 信息缺失时使用视图特征兜底识别
- 对识别出的豆包 PiP 执行 `alpha = 0` + 禁用触摸，不破坏系统 PiP 状态机
- 保留 Bilibili、微信等正常视频 PiP 不受影响

## 兼容

- iOS 16
- Dopamine rootless
- arm64 / arm64e
- mobilesubstrate

## 安装

从 [Releases](../../releases) 下载最新 `.deb`，用包管理器安装后重载 SpringBoard。

## 构建

```bash
git clone --recursive https://github.com/theos/theos.git ~/theos
curl -LO https://github.com/theos/sdks/archive/refs/heads/master.zip
unzip master.zip && cp -r sdks-master/iPhoneOS16.5.sdk ~/theos/sdks/
```

```bash
export THEOS=~/theos
make clean
make package FINALPACKAGE=1
```

## 版本

### 0.0.5
- 修复 clang 模块系统兼容性，支持 GitHub Actions macOS runner 自动编译
- 移除调试日志代码，release 纯净输出