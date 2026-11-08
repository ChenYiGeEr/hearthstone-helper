# HearthstoneHelper

## 项目

本机 macOS 14 的炉石助手。主窗口看卡组、胜率和历史；对局进行时，左边浮窗是对手记录，右边是己方牌库。数据来自本机客户端日志，以及对进程 `unity.Blizzard Entertainment.Hearthstone` 的只读内存。不代替玩家操作，不向游戏注入输入。

网络只访问 hearthstonejson 的 zhCN 卡牌 JSON 和卡图。本地记录不上传。卡牌 JSON 目前只读 `Application Support` 里的缓存，`CardDataStore.download()` 没有调用方。

浮窗默认接收鼠标，穿透是开关，默认关。主窗口关掉不退出，菜单栏把进程留住。

界面字符串用中文。新注释跟所在文件已经在用的语言，不把整个文件翻成另一种语言。

本文件里的句子和代码不一致时，在同一次改动里改掉或删掉那句。不追加更新日志。

## 不变量

手牌 `cardID`，以及手牌、牌库、场面的张数，以 `MirrorMemory` 为准。攻击、武器、奥秘、生命和费用仍来自 `Power.log`。内存整路失败才回退日志。牌库名单是卡组表减去已离开牌库的牌，再加上不在卡组表里的明文牌库实体，那些标成洗入。内存里的牌库实体是空名字，不要改成从内存读牌库名单。菜单态（BattleTag、卡组库、当前卡组、天梯、收藏）走 `HearthMirror`。

胜率百分比和「总场次」只计入 `integrity == .complete` 且结果不是平局的对局。平局仍显示在「胜 / 负 / 平」里，不进总场次。不完整的对局只留在列表里。卡组只从 `Decks.log` 和 `HearthMirror` 来，不加手动导入。复制卡组代码时，英雄和每张牌都要有 dbfId；编不出来就不写剪贴板。对手卡组用这一局英雄的 dbf，不用写死的英雄。

Mono 布局数字不写在本文件。权威在 `MirrorMemory.swift` 和 `Probes/README.md`。要改数字，先用探针对上当前这版客户端。

`Probes/README.md` 的里程碑 F（多局对账、对手侧计数精度）还没签字。不要写成已经长期验证。

没有卡牌缓存时，`CardDataStore.bootstrap()` 下载 zhCN JSON。主窗口在「日志未启用」时提供「启用日志」；只有磁盘上还没有 `log.config` 才写入，不覆盖已有文件。菜单栏不加这个按钮。收藏抓到空牌表不算完成，下次打开再试；已有牌的快照不被空结果盖掉。不要在别的路径再接一次下载或写配置。

## 探针

正式路径是可执行文件里的日志和只读内存。`Probes/` 是独立探针，不在 `Package.swift` 里。改 `Probes/` 或内存读取之前，先读 `Probes/README.md`。

## 构建与验证

同一个 `Sources/HearthstoneHelper` 拆成 `HearthstoneCore`（纯逻辑，测试只链它）和可执行文件 `HearthstoneHelper`（界面、日志、内存、`HearthMirror`）。新的 Swift 文件只能进其中一个 `sources` 列表，并写进另一个 target 的 `exclude`。

改 `HearthstoneCore` 里的解析、卡组码、对局追踪时，同步改 `HearthstoneHelperTests`，用 `swift test` 收尾。不要为浮窗或内存另起一套 UI 测试，除非那次任务明确要求。

可以自己跑 `swift test` 和 `swift build`。`scripts/deploy.sh` 会关掉正在跑的助手，再打开 `~/Applications/HearthstoneHelper.app`。探针和任何 `task_for_pid` 会附着炉石。后两类必须在当次对话里得到明确允许才执行。
