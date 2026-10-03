# Kelivo 历史检索身份路径修复：本地交付记录

日期：2026-10-04，Asia/Shanghai。状态：本地定向验证通过，尚未提交、推送、构建或安装新 IPA，尚未真机验收。不宣称生产故障已彻底解决。

## 版本和安装包证据

- 用户给出的带空格目录不存在；实际源码目录是 `/mnt/d/Kelivo-archive-v1-latest`，HEAD `9e771ccf`，`pubspec.yaml` 为 1.2.5+72，iOS 主包标识为 `psyche.kelivo`。它不能直接作为原 Heartbeat 应用的覆盖安装来源。
- Windows 创建的 worktree `.git` 指向 `D:/Kelivo/.git/worktrees/Kelivo-archive-v1-latest`；WSL 使用显式 git-dir/work-tree 只读核验。初始状态大量 M 主要涉及换行；忽略行尾空白后，本轮最终业务差异限定于下列八个已跟踪文件，另有一个新增测试。原始文件副本保留在 `/tmp/ayan-client-fix-baseline`。没有 reset、clean、切换原分支或改动既有开发成果。
- 原发布分支 `release/ios-heartbeat-archive-v1`，提交 `c437f3278503b39a6af881b2f5f78e31b102a753`，成功构建 [GitHub Actions 33971769774](https://github.com/KoyamaHUANG/kelivo/actions/runs/33971769774)。该版本仍使用 BusinessPreferences，支持原 Protocol 1。
- 本地原产物：`/mnt/d/Kelivo-ios-artifacts/Kelivo-Heartbeat-ArchiveV1-unsigned/`。ZIP SHA-256 为 `e21ccaa4bd1d23aa0723ad9dc80a5ed937dbd340895d5990035c494a0bb9a65a`，与该 Actions 产物 digest 完全一致。ZIP 内 IPA 与旁边保存的 IPA 一致，IPA SHA-256 为 `9d432186e2e14c9ecec561d05e707be16c55358ca491b342b706b012595ad323`。
- 原 IPA 主包为 `com.koyamahuan.kelivo.heartbeat`，版本 1.2.2（66）；扩展为同前缀的 `GenerationActivityExtension`。主包没有 embedded.mobileprovision 和主包 CodeResources；不能用框架的签名文件证明主应用已签名。
- 既有报告记录用户安装了上述原 IPA，但没有本次直接读取手机的证据。当前手机是否仍为该包、实际侧载签名身份均待用户确认；不能仅凭历史记录或相同版本号断言手机版本对应。
- 原包和发布源码未覆盖。为避免引入 1.2.5 的其他功能，从原发布提交独立导出 `/mnt/d/Kelivo-archive-v1-identity-repair`，仅移植本轮身份修复。它是本地源码快照，不是已提交的新分支。

## 已证实的入口差异和日志边界

复用当前会话已取得的生产证据，不重复 Gateway 工具注入调查、不重新查询或导入私人历史。

- 同模型相邻请求 `req-i` 与 `req-j` 的 incoming 摘要相同；前者 binding/protocol/user_send 均有效，工具查询零命中并将 not_found 回传；后者三项均 false，日志为 `legacy_untrusted_user_identity`。不能把它描述为工具执行失败。
- 正常发送此前构建 Heartbeat Headers 和归档身份；重新生成/旧消息重发、编辑用户消息后转入重生成、手动恢复工具回答这三条入口未传这两组参数。
- 普通 `X-Conversation-Id` 不满足原私有历史绑定契约，修复继续使用确认能力后的 `X-Kelivo-Conversation-Id`、`X-Kelivo-Assistant-Id` 与 Protocol 1 Header/信封。
- 生产日志没有客户端操作类型、应用构建 SHA 或能力缓存快照，因此源码入口缺口是已证实的代码原因，但不能把某个具体生产请求武断归为某次重生成点击。
- 新工作区的自动网络重试闭包保留原 headers/identity；原 IPA 发布源码没有该新版自动重试封装。本次未向旧版引入新版重试功能。原有工具自动续传继续使用 continuation 身份。

## 最小修复和兼容性限制

1. 正常发送、重新生成、编辑重发、手动恢复统一调用 `prepareHeartbeatGenerationIdentity`，复用原能力判断、真实消息版本选择和身份构建。
2. 新真实用户消息/编辑产生的新用户修订保存本地请求 ID。缓存作用域包含 provider/规范化 endpoint、conversation、assistant 和真实用户消息 ID；仅保存不透明请求 ID，不保存聊天正文或 API Key，明确剔除 URL 用户凭据、query 和 fragment。沿用 BusinessPreferences，不新增数据库表。
3. 重新生成及手动恢复复用这个已记录的 root request ID；以原真实用户消息身份进行 Protocol 1 请求重放，而不是编造新的用户消息或父请求。原归档存储对相同 request/message 的重放去重，已完成的 assistant 记录保持原有去重行为，不覆盖为新的生成结果。本轮没有操作生产数据库。
4. 编辑重发仅在编辑入口明确允许为新修订构建身份；版本折叠选择与请求消息一致，不把最新版本强加给用户选择的旧版本。
5. 重生成/手动恢复进行能力核验，但不主动拉取事件或建立新的主动同步绑定，避免改变正在重放的上下文。正常发送仍保留原有主动同步时序；主动同步单独降级时不抹掉已经确认的归档协议能力。
6. 注入和裁剪后只通过真实 revision ID 映射归档用户索引；若该用户被移出上下文，明确在客户端失败，不静默丢弃协议，也不借用 synthetic role=user 消息。
7. **旧消息限制：原客户端没有保存随机 root request ID。对没有可信本地记录的旧用户消息，不能创建一个新随机 root 并假装它是原请求，也不能猜测原父请求。符合归档能力的重生成/恢复会提示“历史检索身份未保存：请在当前会话发送一条新消息后再重新生成”。检查发生在删除后续消息、创建 assistant 修订或标记恢复流之前。** 新安装后的新消息及其重生成可验证本轮效果；这不是所有旧消息重生成都能恢复身份的承诺。
8. 无确认能力/无 assistant 绑定时保持普通聊天原契约，不回退到当前选中的其他 assistant，不放宽 Gateway 鉴权。不新增任何生产日志，不输出真实身份值、私人正文或凭据。

## 修改清单

两个客户端源码快照各自仅有七个源码文件、两个测试文件的本轮修复；发布补丁另含本报告：

- `lib/core/services/archive_identity/kelivo_archive_identity.dart`
- `lib/core/services/proactive_sync/heartbeat_proactive_store.dart`
- `lib/core/services/proactive_sync/heartbeat_proactive_sync_service.dart`
- `lib/features/home/controllers/chat_actions.dart`
- `lib/features/home/controllers/home_page_controller.dart`
- `lib/features/home/controllers/home_view_model.dart`
- `lib/features/home/services/message_generation_service.dart`
- `test/core/services/proactive_sync/heartbeat_proactive_sync_test.dart`
- `test/message_generation_identity_test.dart`（新增）

Gateway 只更新本修复记录及原报告的索引，不改任何业务代码、配置、数据、备份或 V2 文件。

## 本地验证

- 使用已有 Flutter 3.44.1 / Dart 3.12.1 Windows SDK，与原 IPA workflow 指定 SDK 相同；没有使用 Windows npm 或 Node。尝试独立 Linux Flutter 的官方/镜像端点返回 404，未替换 SDK 版本或绕过访问限制。
- 原发布候选先离线解析依赖，发现与保存的原 release lock 有 25 项版本差异；随后改用原 `/mnt/d/Kelivo-ios-release/pubspec.lock`，`flutter pub get --offline --enforce-lockfile` 通过。该锁文件 SHA-256 为 `75b8103b9007d2f900a2431d7e711ba32449e10ea771cf2005393f2cdd29ea59`。它证明本次测试的依赖选择，不能独立证明原 CI 当时解析的每个依赖版本。
- 原发布候选七个相关测试文件累计 67 个不同用例通过：Archive identity、stream/nonstream 自动工具续传、能力判断及同步、Header 保护、最终 HTTP 身份一致性、revision 映射及上下文裁剪、各发送入口接线、重生成上下文。最后的缓存脱敏变更仅重跑两个受影响文件，33 项通过；其他已通过项目复用结果。
- 新工作区最后两个受影响测试文件 27 项通过；此前身份/Header 13 项及发送/重生成相关四个文件 44 项通过。重复覆盖不累加成独立用例数量。
- 新增 11 项定向测试：8 项核心身份/缓存/作用域用例、1 项真实本地 HTTP 传输（四种操作）、1 项裁剪/真实 revision 映射用例、1 项实际入口接线与提前失败保护用例。
- 两份源码中本轮九个 Dart 文件 `dart analyze --fatal-infos` 通过，格式化通过。候选 `scripts/validate_ios_heartbeat_archive.py` 通过；没有进行 Xcode 构建。
- 测试仅使用 fixture 身份、虚构正文和回环 HTTP/临时 SQLite。既有测试会出现 asset maintenance MissingPluginException 和 RequestLogger 写入提示，未导致用例失败；未改这些无关模块。
- 过程中的 HTTP 测试曾因 Flutter 默认 HttpClient 阻断返回 400，现以局部 HttpOverrides 连接回环服务器解决。另一次调用误列了旧快照不存在的新版测试文件，该次命令退出失败；删除该不存在路径并使用真实旧版测试清单后通过。未将这些失败冒充成功。
- 本轮尚未执行真机 UI 验收或完整全仓测试。AGENTS 的提交前完整 format/analyze/test 门槛需在正式提交前完成；本报告的通过结论限于上述定向验证。

## 后续提交、构建和安装边界

- 可审阅补丁：`docs/kelivo-history-identity-release-c437f32.patch`；仅针对原 IPA 提交中的上述九个文件及本报告。不是把整个最新 worktree 或测试生成文件送入发布分支。
- 需用户集中授权后才正式提交、推送、触发构建：沿用 `KoyamaHUANG/kelivo` 的 `release/ios-heartbeat-archive-v1` 和原 `build-ios-heartbeat-archive-v1.yml` / macOS / Flutter 3.44.1 无签名 IPA 流程，保留原主包/扩展标识。此客户端修复不需要 Railway 部署或生产配置变更。
- 正式构建前完成提交门槛；确定递增构建号、记录源码 SHA/依赖锁和产物 SHA；依赖锁、workflow 或版本号的正式改动尚未执行，不能假定已有产物能直接覆盖安装。
- 安装前核对手机当前版本、原侧载工具和签名账号/Team（不索取账号凭据），确认新旧签名与 app identifier 兼容；保存现有应用的可读备份。优先原签名覆盖安装，不先卸载，不覆盖唯一备份、不重新导入生产历史。
- 真机验收应在原阿言会话先发送一条新的真实检索消息，再对它重新生成、编辑重发；如触发工具问答，验证手动恢复。结合既有脱敏 Gateway 阶段日志核验 eligibility、注册、执行、结果回传。零命中与身份错误分别记录。此前旧消息缺失 root 的恢复限制单独验收，不伪造恢复成功。


## 2026-10-04 正式发布候选与提交前检查

用户已授权沿原发布基线正式提交、推送和构建无签名 IPA，并明确采用 Sideloadly。原工作区不变；独立 Git 发布仓库为 `/mnt/d/Kelivo-archive-v1-release-identity`，父基线为 c437f32。

- 正式候选版本 1.2.2（67）；扩展版本统一为 1.2.2（67）。主 Bundle ID `com.koyamahuan.kelivo.heartbeat` 及扩展标识均未变，未引入 App Group/Keychain entitlement 或数据库迁移。
- 正式变更清单：原九个源码/测试文件、本报告，加上 `pubspec.yaml`、扩展版本所在的 `ios/Runner.xcodeproj/project.pbxproj`、原 `build-ios-heartbeat-archive-v1.yml` 和锁定的 `pubspec.lock`，共十四个文件。workflow 仍是原专用发布分支、macOS、Flutter 3.44.1、无签名 IPA 流程，仅加入锁文件校验和已有新增定向测试。
- 将原 release 保存的锁文件纳入版本管理，CI 使用 `flutter pub get --enforce-lockfile`，记录 lock SHA-256；没有升级任何依赖。
- 原 Windows 全仓运行有平台路径/文件锁/子进程失败，结果保留，未冒充通过。原 framework 924134a44c、engine c416acfeb8 对应的官方 Linux Dart SDK 与 Flutter 工具/测试运行器已独立配置于 `/tmp`，Linux 全仓 **2813 个可见用例通过，零失败、零跳过**。
- Linux `dart analyze --fatal-infos lib test` 通过。原规则要求格式化改动文件，本轮九个 Dart 文件 `dart format --output=none --set-exit-if-changed` 为零改动。完整 lib/test 格式审计仅发现 `lib/features/backup/pages/backup_page.dart` 一个未修改的基线格式差异；已核验其与 c437f32 字节一致，未将它混入发布。
- SQLite 默认下载器的 TLS 握手失败通过 curl 下载同一官方版本并核对包内预期 SHA-256 解决；未关闭证书验证或替换库版本。全仓测试不访问生产数据库。
- 原流程的测试/构建准备继续将 fallback 常量置空，避免真实密钥进入 IPA；该准备文件不纳入本轮修改。隐私检查只检查本次新增内容并排除真实账号/身份值，不读取 Sideloadly 凭据。
- Sideloadly 缓存的两个 `.ipa` 文件并非标准 ZIP，不能据此核验手机已安装包的签名；没有尝试解密缓存或访问账号密码。用户只需确认旧应用由同一 Apple ID 签名、实际 Bundle ID 未被自定义，以及手机当前版本，无需提供账号地址、密码或验证码。

### Sideloadly 覆盖安装条件

[Sideloadly 官方 FAQ](https://sideloadly.io/faq)明确：覆盖现有应用并保留本地进度需要同一个 Apple ID 和同一个实际 Bundle ID。源码中的 DEVELOPMENT_TEAM 或无签名 IPA 不证明手机现有签名；本轮不签名、不安装。

1. 在旧 Kelivo Heartbeat 中导出聊天、附件、助手与配置备份，确认文件可读并独立保存；不要卸载旧应用或覆盖唯一备份。
2. iPhone 连接原 Windows 电脑、解锁并信任设备，关闭应用中的生成任务。
3. 将本次新 IPA 拖入 Sideloadly，选择该 iPhone，使用原安装时的 Apple ID。账号认证只在用户自己的 Sideloadly/Apple 界面完成。
4. 保留主包和扩展；不启用自定义/更改 Bundle ID、删除扩展或注入 tweak。如 Sideloadly 曾为原版修改实际包标识，停止，不擅自修改本次 IPA。
5. 确认旧应用由同一 Apple ID 和实际标识签名后按 Start 覆盖安装；如提示身份/标识不匹配或要求卸载，取消并保留错误信息，不删除应用数据。
6. 打开应用确认 1.2.2（67）、原阿言会话和设置仍在，再对升级后的新用户消息验证发送、重生成、编辑重发及适用的手动恢复。旧消息无 root ID 的限制维持前文结论。

本报告记录提交前状态。正式源码 SHA、Actions run、IPA/ZIP SHA-256、包内兼容性对比及最终构建结果由构建后的独立交付记录追加，不能将候选检查写成已安装或已真机修复。
