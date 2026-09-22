# BoMD

一款轻量的原生 macOS Markdown 阅读器，专注于阅读本地 Markdown 文档。

## 功能

- 通过文件菜单、拖放或 Finder 打开 `.md` / `.markdown` 文件。
- 渲染视图与只读原文视图切换。
- 深色外观、浅色外观，在「视图」菜单直接切换。
- 标题、列表、表格、引用、链接、图片、代码高亮与数学公式。
- 代码复制、代码自动换行、宽表格横向滚动。
- 多窗口、最近打开文件、重新加载文件。

BoMD 是阅读器，不提供 Markdown 编辑和保存功能。部分扩展语法与 HTML 会受到渲染能力及安全清理规则的限制。

## 系统要求

- Apple Silicon Mac（M 系列芯片）。
- macOS 26.0 或更新版本。

当前构建目标为 `arm64-apple-macos26.0`，不包含 Intel 版本。

## 从源码构建

需要 Node.js 18 或更新版本、npm，以及能够编译 macOS 26 目标的 Apple Command Line Tools 或 Xcode。无需 Xcode 工程，也无需 Apple Developer 付费账号即可进行本地构建。

```bash
git clone https://github.com/b0vibe/BoMD.git
cd BoMD
npm ci
npm run build
open build/BoMD.app
```

构建脚本会打包 Web 渲染器、编译 Swift 源码、复制依赖资源，输出 `build/BoMD.app`。默认使用临时签名（ad-hoc），仅用于本地构建；它不是经过 Apple 公证的正式分发版本。反复重新构建可能导致 macOS 再次请求文件访问授权。

如果已安装完整 Xcode，但系统当前选中了其他工具链，可以仅为本次构建指定：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer npm run build
```

### 使用自己的开发者证书

已有 Developer ID Application 证书及对应私钥时，可显式指定证书名称：

```bash
BOMD_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' npm run build
```

此方式启用 Hardened Runtime 并获取安全时间戳。公开分发仍需单独完成 Apple 公证和票据附加；构建成功不代表公证完成。仓库不包含签名私钥、账号密码或公证凭据。

## 使用

| 操作 | 快捷键 / 菜单 |
| --- | --- |
| 打开文件 | `⌘O` |
| 新建阅读窗口 | `⌘N` |
| 切换原文 / 渲染 | `⌘R` |
| 重新加载文件 | `⇧⌘R` |
| 切换外观 | 视图 → 深色外观 / 浅色外观 |

文档在本机读取和渲染。文档引用的远程图片或你主动打开的外部链接可能产生网络访问。应用在本机保存偏好、最近打开记录及诊断日志；日志目录为 `~/Library/Logs/BoMD/`。访问受保护文件夹时，请按 macOS 提示授权。

## 项目结构

- `BoMDApp/Sources/`：SwiftUI、AppKit 与 WebKit 原生应用。
- `BoMDApp/Web/src/`：Markdown 渲染器源码。
- `BoMDApp/Resources/`：HTML、CSS、图标及生成的渲染脚本。
- `scripts/build_app.sh`：本地应用构建脚本。
- `package.json` / `package-lock.json`：Web 依赖与锁定版本。

此仓库只包含公开构建所需文件，不包含内部开发记录、测试资料或个人环境配置。

## 许可证

BoMD 自有代码采用 [MIT 许可证](LICENSE)。第三方代码、字体、数据和图标继续遵循各自许可证，见 [第三方许可说明](THIRD_PARTY_NOTICES.md)。
