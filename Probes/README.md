# Mono 内存遍历探针（Q2 项目）

阶段化验证游戏内存读取的探针集。每个探针独立可运行（swiftc 直接编译 + 调试权限签名）。

## 运行方式
```
swiftc -O Probes/stageN_xxx.swift -o /tmp/stageN
codesign --force --sign - --entitlements scripts/debugger.entitlements /tmp/stageN
/tmp/stageN
```

## 里程碑
- ✅ A：附着游戏进程 → 定位 mono dylib → 读 MonoDomain*（stage1_attach.swift）
- ✅ B1：MonoDomain+0xB0 assemblies → Assembly-CSharp image → BSJB 元数据根（stage2/stage3）
- ✅ B2：#~ 表头解析 + TypeDef 表偏移校准（stage4b_alignment_search.swift）
  - **TypeDef 数据起点 = tilde+0x573C，行大小 22**（flags4 name4 ns4 extends2 fieldList4 methodList4）
  - 坑：行数数组必须按 validMask 出现序号取（`24 + ord*4`），Field 91786 / MethodDef 113059 均 >65535 → 简单索引 4 字节
- ✅ B3：全量类名枚举（stage4_typedef_enum.swift）→ /tmp/assembly_csharp_classes.txt
  - 14363 个 TypeDef，7932 有效类名，90 命名空间（Blizzard.T5.* / Hearthstone.* / 全局）
  - **推翻 stage2c 结论：GameState / Gameplay / Player / Zone / EntityDef 全部存在**
- ✅ B4：MonoClass 定位（stage5/5b/5c/6/7）
  - image 哈希表是方法/类型缓存但布局与教科书不符；MonoClass 惰性加载使 class_cache 不全
  - 决定性方案 = **GC 堆全扫**（mach_vm_region 枚举 + 本地扫 [p+0x38]==image）
- ✅ B5：GameState vtable + 实例（stage8/8b/9）
  - **MonoVTable 布局（Unity fork，无 MonoObject 头）：klass@0x00，domain@0x10**
  - vtable 定位 = 堆扫 [w]==类指针 && [w+0x10]==domain
  - 实例定位 = 堆扫 [obj]==vtable 指针（注意排除类槽位结构假阳性）
- ✅ B6：静态字段读取配方端到端验证（stage11/12 + 反汇编定案）
  - 元数据 Field 表：Field 行 = flags(2)+name(4)+sig(4)=10 字节；Field 表紧跟 TypeDef（tilde+0x5298E）
  - **MonoClassField（实测）**：type@0x00、name@0x08、parent@0x10、offset@0x18，条目步长 0x20
  - **fields 数组位置 = MonoClass+0x90**（GameState 首条目 'DEFAULT_SUBOPTION' 与元数据 fieldList 吻合）
  - **静态存储公式（反汇编 _mono_vtable_get_static_field_data）**：
    `data = *(vtable + *(i32*)(klass+0x54)*8 + 0x48)`；初始化标志 = vtable+0x2F bit2
  - 端到端验证：CollectionManager.s_instance = 0x13e112960，[obj]==vtable ✓
  - GameState.s_instance = null（菜单态，符合预期）；对局中的验证待用户开一局
- ✅ C：对局实时数据全链路读取成功（stage13_live_match.swift）
  - GameState.s_instance → 实体验证 ✓（m_playerMap/m_entityMap 非空）
  - ZoneMgr.s_instance → m_zones（List<Zone>，实测 52 区域）→ 每区域 m_cards 计数
  - 实测读出：手牌 9/8、牌库 23/16、场面 2/5、坟场 19/19、英雄/英雄技能/奥秘/武器区齐全
  - side 字段区分玩家（1/2）；friendly 判定待接 Player.m_local
- ✅ D1：MirrorMemory 模块产品化（Sources/HearthstoneHelper/MirrorMemory.swift）——后台扫描+1s 轮询，MatchStore/DashboardView 已接（侧栏金色角标：手/库/场 实时计数）。探针 stage14 验证 Player.m_local 己方判定 ✓
- ✅ D2：浮窗统计条/区域标题全接入 MirrorMemory 实时计数（OverlayPanels mergedSideStats 合并逻辑，SideStatsBar deck/hand/board、zoneGroup total 全覆盖，对手牌库计数彻底精确化）
- ✅ E：friendly 卡组视角修复——"牌库不减少"根因=已抽判定错误泛化 floor 机制（T5 初始实体整局存活，抽牌=普通区域移动）；修复后 tracker 剩余=内存 ZoneDeck 计数（6=6 验证）；换牌窗口保留 floor 逻辑
- ✅ G：内存优先数据源改造（stage16/18）
  - **手牌身份从内存读**：ZoneHand.m_cards → Card.m_entity @ +0x28 → 实体 cardID MonoString @ +0x28（stage16 实测 6/6 与客户端一致）；**MonoString（本 fork）：len(i32)@0x10、UTF-16LE 字符@0x14（无 MonoObject 头）**
  - MirrorMemory 每秒轮询同时发布 friendlyHandCardIDs；浮窗手牌列表以内存 cardID 为准（T5 日志换牌重发期滞后），日志只提供费用/来源元数据，内存读不到时整体回退
  - **牌库身份仍不可读**（牌库实体匿名/共享空串），牌库列表保持"卡组表 − 已抽取"投影；但**洗入牌库的外来牌（炸弹/瘟疫/衍生）T5 会物化成明文 DECK 实体** → tracker 把不在卡组表里的 DECK 实体合并进牌库列表，标记为衍生（.generated，浮窗显示"洗入"角标）
  - 浮窗动画：TrackedCard.rowKey（cardID，跨快照稳定）驱动 ForEach diff，抽出=向下滑出、洗入=向下滑入+计数数字滚动
  - 验证脚本：stage18_all_friendly_zones.swift（己方全区域卡牌身份 dump）
- ⏳ F：长期实战验证（多局对账）+ 对手侧计数精度确认

## 探针清单
- stage1_attach.swift：Mach 附着 → dyld 镜像表 → libmonobdwgc → ADRP/LDR 解码 → MonoDomain*
- stage2_domain_walk.swift：MonoDomain 布局（+0x0C0 friendly_name，+0x0B0 domain_assemblies GSList）
- stage2b_assemblies.swift：枚举域内程序集 → Assembly-CSharp image 定位
- stage2c_class_cache.swift：MonoImage 指针字段诊断 dump
- stage3_metadata_root.swift：MonoImage+0x70 = raw_metadata → BSJB → 流头解析
- stage4b_alignment_search.swift：TypeDef 表锚点/行大小自动校准
- stage4_typedef_enum.swift：全量 TypeDef 枚举 → 类名落盘 /tmp/assembly_csharp_classes.txt
- stage5_class_cache.swift：MonoImage 哈希表签名扫描（失败——布局不符）
- stage5b_image_struct_dump.swift：MonoImage 后段原始结构 dump（哈希表真布局探查）
- stage5c_class_scan.swift：宽容桶扫描（受惰性加载限制）
- stage6_find_classes.swift：MonoClass BFS 链遍历（Entity/Player 命中，验证 +0x38/+0x40 签名）
- stage7_heap_class_scan.swift：**GC 堆全扫定位 12 个核心类**（2.6GB / 9506 类）
- stage8_static_fields.swift / stage8b_vtable_scan.swift：vtable 路线探索
- stage9_singleton.swift：vtable → 实例定位 + dump

## 容器布局（本 fork 实测）
- List<T>：_items@0x10（数组指针）、_size@0x18（u32）、_version@0x1C
- MonoArray：bounds@0x10（szarray=null）、**length@0x18、vector@0x20**（与经典 mono 不同！）
- 假阳性警告：堆扫 [w]==vtable 会命中类槽位结构（klass+0xC8 槽位数组里存着 vtable 指针值），单例必须走静态读取

## 关键技术事实
- 游戏 Mono = libmonobdwgc-2.0.dylib（bdwgc=Boehm GC），`_mono_get_root_domain` 偏移 0x11853c（arm64/x86_64 同值）
- **dylib 在磁盘上有完整导出符号**（nm/otool -arch arm64 本地分析，无需猜结构体！）
- MonoDomain+0xB0 = domain_assemblies GSList；MonoAssembly+0x60 = MonoImage*；MonoImage+0x70 = raw_metadata（BSJB）
- MonoImage：+0x20 file_name、+0x30 assembly_name、+0x38 module_name、+0x58 guid、+0x70 metadata、~0x0C0-0x4B8 tables[64]、0x4C8+ 各类缓存哈希表
- **MonoClass 实测布局**：element_class@0x00、cast_class@0x08、parent@0x10、image@0x38、name@0x40、name_space@0x48（指 #Strings 堆）、type_token@0x50（u32，TypeDef 1-based 行号）
- **MonoVTable 实测布局（Unity fork 无 MonoObject 头）**：klass@0x00、domain@0x10
- MonoMethod：flags/iflags@0x00、token@0x04、klass@0x08、name@0x10
- HashEntry（MonoGHashTable）：hash@0x00、key@0x08、value@0x10、next@0x18
- vtable 查找机制（反汇编 mono_class_vtable）：槽位数组 {u16 count, slots[]@+8}，索引 = klass+0xA4(i32)
- mono 惰性加载：class_cache 只含已触碰的类 → 全类定位必须堆扫
- 运行时地址每次游戏重启都变，**偏移才是稳定的**
- 探针需先 dlopen HearthMirror 调 `acquireTaskportRight()`（否则 task_for_pid 被拒）
- Swift 探针坑：负数转 UInt64 会 trap、Int(超大 UInt64) 会 trap、stdout 缓冲在 SIGTRAP 时丢失（崩溃无输出≠没跑到）

