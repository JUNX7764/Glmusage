# 开发者说明

从源码构建（开发者，需要 Xcode Command Line Tools，未装先执行 `xcode-select --install`）：

```bash
./build.sh
```

发布新版本（开发者，要求工作区干净且已推送）：`scripts/release.sh v1.2.3`——创建本地 tag → 构建与离线自测（含 Peak）→ 签名及 DMG/zip 校验 → 推送 tag → 创建 GitHub Release。若同名 Release 已存在（人工创建或上次上传中断），会补传/替换完整附件。验证失败不会推送远端 tag。

## 原理

- **凭据**：只读 ZCode 本地加密凭证库 `~/.zcode/v2/credentials.json`（AES-256-GCM，密钥派生与 ZCode 客户端一致：环境变量 `ZCODE_CREDENTIAL_SECRET` 或 `zcode-credential-fallback:darwin:<homedir>:<username>`），内存中解出订阅 api-key，不落盘、不写入本仓库
- **接口**：智谱开放平台监控接口（与官方 glm-plan-usage 插件同源）
  - `GET https://open.bigmodel.cn/api/monitor/usage/quota/limit`
  - `GET https://open.bigmodel.cn/api/monitor/usage/model-usage?startTime=&endTime=`
  - `GET https://open.bigmodel.cn/api/monitor/usage/tool-usage?startTime=&endTime=`

## 隐私与安全

- 纯本地运行，凭据不离开本机
- 凭据只读解出 api-key，不落盘、不写入本仓库

## 调试与自检

```bash
# 离线自检：只用临时目录和离线假数据，不读 ZCode 凭据、不联网
./GlmUsage.app/Contents/MacOS/GlmUsage --self-test
./GlmUsage.app/Contents/MacOS/GlmUsage --peak-test

# 脚本回归：PATH mock 故障注入，不操作真实 app、LaunchAgent 或 GitHub
python3 -m unittest discover -s tests -p '*_test.py'

# 真实自检：读取本机凭据、联网拉一次数据后退出
./GlmUsage.app/Contents/MacOS/GlmUsage --once

# 无 ZCode 凭证库时可用环境变量提供 key
GLM_API_KEY=xxx ./GlmUsage.app/Contents/MacOS/GlmUsage --once
```

运行状态自诊断写入 `~/Library/Application Support/GlmUsage/status.json`。

## 文件说明

| 文件 | 说明 |
|---|---|
| `GlmUsage.swift` | 全部源码（单文件 AppKit 菜单栏应用） |
| `build.sh` | 编译 + 打包 + ad-hoc 签名脚本 |
| `Info.plist` | App Bundle 配置（LSUIElement = 菜单栏常驻） |
| `scripts/icon_gen.swift` | 图标生成脚本（缺 icns 时 build.sh 自动调用） |
| `scripts/update.sh` | 就地更新脚本（从 Release 下载替换；build.sh 随包内置进 .app Resources） |
| `scripts/release.sh` | 发布脚本（本地 tag → 构建与测试 → 资产校验 → 推 tag → GitHub Release） |
| `tests/script_test.py` | 更新、发布、签名故障的离线回归测试 |
