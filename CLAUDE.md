# CLAUDE.md

本仓库是 PowerBoard，一个 macOS 原生应用，统计本机 Claude Code 和 Codex 的 token 用量，并估算对应的服务端耗电和碳排。

完整需求见 `docs/SPEC.md`。开始任何工作前先读完它。

## 工作方式

- 按 `docs/SPEC.md` 第 15 节的里程碑顺序开发，一次只做一个里程碑。
- 每个里程碑结束时：运行全部测试，确认构建成功，在 `docs/DECISIONS.md` 记录本阶段做出的决定和偏离规格的地方，然后提交一次 git commit。不要推送到远程仓库。
- 规格中没有写清楚的地方，选择最简单的合理做法，并记录到 `docs/DECISIONS.md`。如果问题会影响数据准确性或用户数据安全，先停下来询问。
- 不要修改 `docs/SPEC.md`。如果认为规格有错，在 `DECISIONS.md` 里说明。

## 常用命令

```bash
xcodegen generate                                   # 修改 project.yml 后
swift test --package-path Packages/ElectricityCore  # Core 单元测试
xcodebuild -project PowerBoard.xcodeproj -scheme PowerBoard -configuration Debug -derivedDataPath build/DerivedData build
# 开发用：把本机日志读入指定数据库并打印汇总（只输出计数，不输出日志内容）
swift run -c release --package-path Packages/ElectricityCore ElectricityDev <数据库路径>
# CLI（构建后在 App 包内）；用 CLAUDE_CONFIG_DIR 指向临时目录测试安装，避免改动真实配置
"build/DerivedData/Build/Products/Debug/PowerBoard.app/Contents/Helpers/powerboard" statusline < /dev/null
python3 -I scripts/check-strings.py                 # String Catalog：中英文齐全、无缺失键、无废弃键
scripts/build-release.sh                            # Release 构建（临时签名、通用二进制），输出 dist/*.zip
```

如果命令名或 scheme 名与实际不同，以 `project.yml` 为准，并更新本节。

## 硬性规则

- 不读取、不保存、不打印日志中的对话内容。只处理 SPEC 第 4 节列出的字段。
- 测试数据必须是手写或脱敏的，不能把本机真实日志复制进仓库。
- 产品名、Bundle ID、CLI 名、数据目录名只能通过 `AppIdentity` 引用。
- 所有界面文字放进 String Catalog，同时提供简体中文和英文。CLI 默认英文。
- 图标只用 SF Symbols，通过 `App/Sources/Icons.swift` 中的常量引用（2026-10-12 用户决定，替代 SPEC 11.1 的 Phosphor，见 `docs/DECISIONS.md`）。不使用 emoji，不使用其他图标库。
- 代码注释、提交信息、文档和界面文案都不使用 emoji。
- 文案遵守 SPEC 第 11.3 节：直接、具体，不用营销语气。
- 引入新依赖前确认许可证为 MIT、BSD 或 Apache-2.0，并更新 `THIRD_PARTY_NOTICES.md`。不复制 GPL 代码，不复制 Vibe Island 的任何内容。
- 移植 claude-carbon 的系数时，在 `THIRD_PARTY_NOTICES.md` 中保留其 MIT 许可证和版权声明原文。
- 不写入 Claude Code 或 Codex 的配置文件，唯一例外是 SPEC 第 8.3 节规定的 statusLine 安装流程，且必须先备份。

## 代码风格

- Swift 严格并发检查开启，不留警告。
- 解析和数据库操作放在后台 actor，主线程只做 UI。
- 估算值在类型层面带上区间（low / mid / high），不要只传一个 Double。
- 解析器遇到无法识别的行时跳过并计数，不能崩溃，也不能静默吞掉错误而不计数。
