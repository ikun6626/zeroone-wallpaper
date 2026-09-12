# ZeroOne 宠物壁纸 - 变更日志

> 所有代码改动均记录在此文件中，按时间倒序排列。

---

## 2026-09-12 阶段 2：预览铺满屏幕 + 保存比例双出口

> 起因：实际运行反馈"图片不是 9:16，预览和保存为壁纸时还是原比例，很怪"。
> 代码复核后确认是**两条独立成因**，不是同一个 bug。

| 问题 | 根因 | 修复 |
|---|---|---|
| 预览比例怪、上下留黑边 | `ImagePreview` 用 `ImageFit.Contain` 完整显示原图，与"设为壁纸"后的实际效果完全不一致 | 改为 `ImageFit.Cover` **铺满屏幕**（预览即壁纸效果）；放大后拖动用 `ViewMath.maxPan()` 夹在可视余量内，永不露黑边 |
| 存下来还是原比例 | `saveToAlbum()` 是把原图**下载后原样拷进相册**，与屏幕尺寸无关，全程没有任何合成 | 底部新增"铺满屏幕 / 原图比例"切换：铺满屏幕走 `composeCoverToJpeg()` 按设备屏幕像素离屏合成（cover + 当前缩放/平移 = 所见即所存）；原图比例直接落原始文件字节（完整原图、不裁切不缩放） |
| 预览与导出构图可能对不上 | 预览侧与导出侧各写一套坐标 | 两侧共用 `ViewMath`：预览把 vp 位移归一化成 `ViewTransform`，导出用同一个 `drawRect()` 取景 |

- 新增 `ImageComposer.composeCoverToJpeg(base, baseW, baseH, canvasW, canvasH, t, quality)`：按画布尺寸合成导出（原 `composeToJpeg` 保持不动，继续给编辑器用）。
- 新增 `ViewMath.maxPan(scale, extent)`：cover 铺满后的最大可平移量 `(scale-1)*extent/2`，是预览夹紧手势的唯一出处，带单测。
- `ImagePreview` 新增 `saveMode`（0 铺满屏幕 / 1 原图比例）、`frameW/frameH`（`onAreaChange` 记录预览区尺寸）与底部比例胶囊。

验证：`hvigor … test` 13 个用例全绿；`clean` + 标准 `assembleHap` 通过。

踩坑记录：**不带 `--incremental` 的 `assembleHap` 可能在最后一步报 `Error Code: 00308018`**，日志里是 `entry:default@SignHap is not an incremental task`，而同一份日志前面已经打印 `sign app success` 且 HAP 正常生成 —— 属于 hvigor 自身的记账 bug。按 `DELIVERY.md` 的标准命令（带 `--incremental`）重跑即通过；这也解释了文档里"hvigor 常以退出码 1 收尾"的旧记录。

---

## 2026-09-12 阶段 1：统一画布几何层（common/canvas）

> 起因：预览、编辑、导出各写一套坐标，导致"预览一种构图、存下来另一种"，且文字/贴纸位置换设备就漂移。
> 本阶段只落地**纯几何地基**（不改动现有页面行为），后续裁剪重写、预览铺满、双导出模式都复用同一套函数。

| 项 | 内容 |
|---|---|
| 新增 | `common/canvas/ViewTransform.ets`：`ViewTransform`（归一化 scale/offsetX/offsetY + 90° 步进旋转 + 镜像）与 `ViewMath`（cover 基准、绘制矩形、`sourceRect` 画布↔原图区域映射、平移夹紧、vp→px 拖拽、捏合缩放、导出长边护栏）、`LayerMath`（文字/贴纸的归一化坐标与尺寸换算）。**刻意不 import 任何 `@kit.*`**，因此可被单元测试直接引用。 |
| 新增 | `common/canvas/CanvasSpec.ets`：画布尺寸取自设备屏幕**物理像素**（`display.getDefaultDisplaySync()`），拿不到时回退 1080×1920；提供 `density()` 做 vp↔px 换算、`MAX_LONG_EDGE=4096` 做导出内存护栏，并预留 `OutputMode`（CANVAS / NATIVE / ORIGINAL）三种导出语义。 |
| 新增 | `entry/src/test/CanvasGeometry.test.ets`：12 个用例覆盖 cover 基准、绘制矩形铺满、`sourceRect` 与缩放关系、平移夹紧、无富余方向不可拖、vp→px 换算、捏合上下限、90° 旋转换宽高、图层坐标跨机型等比、长边护栏。已在 `List.test.ets` 注册。 |
| 验证 | `hvigor … test` 全绿（覆盖报告见 `entry/.test/default/outputs/test/reports/`）；`clean` 后全量 `assembleHap` 通过。 |
| 踩坑记录 | ArkTS **不允许同名方法的多个实现**（哪怕参数个数不同）：`ViewMath.clamp(...)` 与数值版 `clamp(v,lo,hi)` 冲突报 `Duplicate function implementation`，数值版改名 `clampValue`。另外 **hvigor 增量编译会漏编新增文件**：新增源文件后必须 `clean` 一次或用 `test` 任务验证，否则 `assembleHap` 可能"通过"却根本没编到新代码。 |

---

## 2026-09-12 工程清理（git 基线 + 死代码删除 + 权限瘦身）

| 项 | 内容 |
|---|---|
| 纳入版本控制 | 工程此前**无 git**（改错不可回滚，也是死代码"不敢删"的原因）。已建立本地仓库并提交改造前基线，此后所有改动走提交历史。 |
| 删除死代码 | 删除 `common/components/StickerCanvasComponent.ets`、`common/sticker/{StickerProcessor,WallpaperExporter}.ets`、`pages/PhotoEditorPage.ets`、`common/photoeditor/{model/EditState,service/ImageRenderer,utils/CoordinateMapper}.ets` 共 7 个文件，连同 `DEPRECATED.md` 一并删除，空目录 `common/sticker/`、`common/photoeditor/` 移除。删除前 grep 复核：全工程唯一的外部引用只剩 `PixelScope.ets` 注释里的一处举例（已改写），`main_pages.json` 也未注册 `PhotoEditorPage`。 |
| 权限瘦身 | 移除 `ohos.permission.READ_MEDIA` 及其 `read_media_reason` 文案。相册读取走 `PhotoViewPicker`（系统选择器免权限）、写入走 `SaveButton` 临时授权，代码中不存在任何需要该权限的调用。现仅声明 `ohos.permission.INTERNET`。 |
| 忽略规则 | `.gitignore` 追加：签名密钥材料（`*.p12`/`*.csr`/`*.p7b`/`*.cer`）、DevEco `material/` 缓存、与本工程无关的 `dsh-deep-whale/`、仓库目录自身。 |
| 文档同步 | `ARCHITECTURE.md` 删除"已隔离（无调用方）"子图与 DEPRECATED 表行；`DELIVERY.md` 代码结构与"已知取舍"按删除后的状态更新。 |

---

## 2026-09-12 交互与商业化审计整改（方案一~六 + 收尾）

> 起因：对全工程做了一次**交互与商业合理性审计**，共 15 项问题（高/中/低分级）。
> 本轮按优先级逐条整改，每轮都跑 `hvigor assembleHap` 编译通过，并对产物做 HAP 字节审计，
> 确认新代码/新文案确实进了包（避免"改了但装的是旧包"）。

### 方案一：设为壁纸闭环 + 虚假承诺文案整改

| 项 | 内容 | 文件 |
|---|---|---|
| 新增 | `SetWallpaperGuide.ets`：「设为壁纸」的**唯一文案来源**（步骤文本、弹窗、页内引导卡片、复制步骤） | `common/components/SetWallpaperGuide.ets` |
| 新增 | 预览页加「设为锁屏 / 设为桌面」主 CTA（SaveButton 安全控件，点击才拿到临时写相册授权）；保存成功后弹引导卡片，**引导在回调之外渲染** | `ImagePreview.ets` |
| 修复 | 贴纸工作台的「存为锁屏 / 存为桌面」原来是**纯 Text 点击**，没有 SaveButton 授权 → 真机 `createAsset` 必然报权限错误。已改为 SaveButton | `StickerStudioPage.ets` |
| 整改 | 删除"一键设为壁纸""直接设为壁纸"等做不到的承诺，玩法贴士补一条说明系统限制 | `StickerPage.ets` |
| 顺带 | 移除预览页只弹"更多功能开发中"的死按钮 | `ImagePreview.ets` |

### 方案二：数据层改造（缓存优先 + 分页可恢复 + 三态）

- **`WallpaperStore` 重写**：新增 `StoreKeys` 六个 AppStorage 状态键（list/loading/loadingMore/more/error/offline/fromCache）；
  启动**先同步读本地缓存**再后台刷新（不再无条件清空 → 永不黑屏）；分页失败**只置 error、绝不把 more 置 false**（此前一次弱网就永久锁死）；
  新增 `retry()` 与 `clearCache()`；缓存用 DTO 显式往返（`tagList/avgRating` 是原型 getter，直接 JSON.parse 会崩）。
- **`PreferenceUtil`**：新增 `isReady/getString/setString/remove` 通用 KV 与 `favoriteIds` 广播（后者在收尾阶段使用）。
- **`HomePage`**：三态渲染（骨架屏 / 错误重试 / 列表）+ 离线提示条 + 底部"加载失败，点击重试"；`remoteReady` 加上限。
- **离线不降级**：云查询失败时若已有缓存内容则**保留**，只有真的没内容才用内置兜底。

### 方案三：PixelMap 内存泄漏（H4）

- **根因**：全工程 6 个文件创建 PixelMap，只有 2 个文件释放；`ImageEditor` **完全没有 `aboutToDisappear`**，
  且每次旋转/裁剪/滤镜替换 `curPixelMap` 都不释放旧图（1080×1920 RGBA ≈ 8MB/次）。
- 新增 `common/utils/PixelScope.ets`：`safeRelease()` + `setCurrent()`（旧图**延迟 300ms** 释放，避免释放正在绘制的句柄）+ `dispose()`。
- `ImageEditor`：加 `aboutToDisappear`、释放 `ImageSource`、3 处替换改走 `setCurrent`。
- `StickerStudioPage` / `StickerBoardPage`：截图与 `ImagePacker` 释放；**沙箱临时文件此前从不删除**，一并清理。
- `WallpaperExporter`（已废弃）内部泄漏也堵上，并补所有权文档。
- `ImageEditor.cleanupStaleFiles` 的临时文件前缀清单补齐（覆盖工作台/画板产物）。

### 方案四：返回键拦截 + 放弃编辑确认 + 导出防重复

- 新增 `common/utils/EditGuard.ets`：带 id 的返回键处理**栈** + `confirmDiscard()`（弹窗异常时保守返回"不关闭"，绝不误丢创作）。
- `Index.onBackPress()` 把返回键交给最上层覆盖层 —— **修掉"在大图预览里按返回键直接退出 App"**这一真实事故。
- 5 个覆盖层接入：引导卡片 → 编辑器 → 工作台/画板 → 预览，优先级由注册顺序决定。
- `ImageEditor` 增加 `dirty` 跟踪（在 `refreshPixelMap`/`commitBytes` 两个**汇聚点**标记，自动覆盖旋转/翻转/裁剪/滤镜/纹理，另加文字贴纸 6 处）。
- 三个导出入口：保存中 `.enabled(false)` + 「正在保存…/正在导出」进度提示（此前点了毫无反馈，用户会连点产生重复相册图）。
- **踩坑记录**：`SaveButton` 是安全控件，**属性集受限** —— 加 `.opacity()` 会编译报错 `Property 'opacity' does not exist on type 'SaveButtonAttribute'`。

### 方案五：导出与预览一致（WYSIWYG）+ 贴纸旋转

| 问题 | 原因 | 修复 |
|---|---|---|
| 导出文字偏细 | 预览 `FontWeight.Bold`，导出是常规字重 | 导出改 `bold ...px sans-serif` |
| 系统字体调大后两侧不一致 | `fontSize(number)` 默认单位是 **fp**（跟随系统字体缩放），导出按 vp 换算 | 预览显式写 `` `${22*t.scale}vp` `` |
| 字号越大导出阴影越大 | 预览的阴影是**固定 vp**，导出却乘了 `t.scale` | 导出只乘 `k`，并按预览逐项对齐颜色/半径/描边宽度 |
| emoji 变乱码、英文被劈开 | 换行按 UTF-16 码元逐字符切分 | 先切"排版单元"（emoji 整体 / CJK 逐字 / 西文整词），断行优先回退到空格 |
| 编辑器贴纸不能旋转 | `StickerItem` 连 `angle` 字段都没有（工作台/画板早就能转） | 模型加 `angle` + 预览 `.rotate()` + `RotationGesture`（基准角+手势角，归一化）+ 导出绕中心旋转 + 角度滑杆 |
| **选中时位置就偏了**（新发现） | 尺寸滑杆嵌在会移动的 Column 里，把本体撑高顶偏 | 滑杆改为**兄弟节点**渲染，本体布局不再受选中态影响；位置按 `sliderOffsetFor()` 动态计算 |

### 方案六：合规入口 + 死代码隔离

- 新增 `common/components/LegalDocPage.ets`：隐私政策 / 用户协议 / 关于与版权，内置文本（离线可看），返回键可关。
  内容对真实行为撰写：不采集个人信息、收藏仅本机、SaveButton 临时授权的权限说明、AGC 作为第三方、"设为壁纸受系统限制"如实说明、图片来源署名与侵权下架渠道、主体信息占位。
- 新增 `common/utils/AppInfo.ets`：版本号实时读取（此前 `v1.0.0` 硬编码在文案里，改版本必然忘记同步）。
- 「清除缓存」：清壁纸缓存 + 沙箱临时文件，**明确不删收藏**（用户资产）与 `stickers` 目录（用户素材）。
- `MinePage` 加「法律与关于」入口卡片；帮助页"关于我们"改用实时版本号并加合规链接。
- **死代码隔离**：7 个无调用方文件（`StickerCanvasComponent`、`StickerProcessor`、`WallpaperExporter`、`PhotoEditorPage` + `photoeditor/` 三件套）
  加弃用横幅，新增 `entry/src/main/ets/DEPRECATED.md` 清单与复核方法。项目**无 git**，删除不可恢复，故未直接删。
- **更正审计结论**：首轮报告称"画板有装饰 🗑 无 onClick"**有误** —— 复核后两个 🗑 都绑了 `removeSelected()`；该结论依据的是被重写前的旧版本，现作废。

### 收尾：L2 / L3 / 删除角标 / 文档同步

- **L2 假"期号"**：原来用 `Date.now()` 推算，每天 +1 但内容不变（"假更新"）。改为按列表里**最新一条的 `uploadTime`** 推导，
  文案变成「第 N 期 · M月D日更新」——内容不更新，期号就不变。`HomePage.issueLabel()`
- **L3 收藏跨 Tab 不同步**：四个页面此前各自 `getFavoriteIds()` 读一次，而 Tab 切换不会重走 `aboutToAppear`。
  改为 `PreferenceUtil.publishFavorites()` 广播到 `AppStorage('favoriteIds')`，页面统一 `@StorageProp('favoriteIds')` 订阅；
  移除所有对 `@StorageProp` 变量的手动赋值。`HomePage` / `CategoryPage` / `MinePage`
- **删除角标跟随贴纸**：原来固定在 `position({x:'50%', y:'90%'})`，选画面顶部的贴纸时按钮还停在底部。
  改为挂在 `StickerNode` 内部，并用**反向缩放**（`1/zoom`）保证点击尺寸恒定、**反向旋转**保证正立。`StickerBoardPage.ets`
- **文档同步**：`ARCHITECTURE.md`（架构图 + 横切机制表 + 数据流）、`DELIVERY.md`（代码结构 + AGC 步骤 + 14 项验证清单 + **上架前检查清单**）、
  本 `CHANGELOG.md` 全部按当前代码重写；新增 `DEPRECATED.md`。

### 未处理 / 已知事项

- 导出排版与 ArkUI 排版无法 100% 逐像素一致（Canvas 无增量测宽接口，且断行规则不完全公开）；CJK/emoji/英文整词已对齐。
- 内置壁纸仍是占位图（picsum + 自有宠物图）。
- 7 个历史遗留文件只做隔离未删除（等确认后再删）。

---

## 2026-09-11 裁剪功能苹果化 + Code Review 修复

### 裁剪功能改造（仿苹果照片）

#### P0: 基础裁剪增强
- **补全裁剪比例**：新增 4:3、16:9 两种比例，共 6 种（自由/1:1/3:4/9:16/4:3/16:9）
  - 文件：`common/editor/CropGeometry.ets`
- **四边把手**：新增上/下/左/右边中点把手（type 4-7），固定比例下联动收缩
  - 文件：`common/editor/CropGeometry.ets` — `calcCropRect` 从四角扩展为八把手
- **旋转/镜像搬入裁剪面板**：不再需要切到 transform tab，裁剪界面内直接操作
  - 文件：`common/components/ImageEditor.ets` — 裁剪底部面板

#### P1: 图片可拖动 + 双指缩放
- **裁剪态图片可拖动**：PanGesture + cropOffsetX/Y，按住选区内拖动图片
  - 文件：`ImageEditor.ets:815-841`
- **双指缩放**：PinchGesture + cropScale（0.5x~5x），选区内捏合缩放图片
  - 文件：`ImageEditor.ets:815-841`
- **手势优先级**：把手 PanGesture > 图片 PanGesture，不冲突

#### P2: 任意角度旋转 + 裁剪专用重置
- **任意角度旋转滑块**：-45°~+45°，cropAngle 状态（后因 applyCrop 坐标问题移除，仅保留 UI 预览）
  - 文件：`ImageEditor.ets`
- **裁剪专用重置**：resetCrop() 只清裁剪参数，不影响滤镜/文字/贴纸
  - 文件：`ImageEditor.ets`

### Code Review 修复（5 项高/中优先级）

| # | 问题 | 修复 | 文件 |
|---|------|------|------|
| 1 | applyCrop 忽略 cropOffset/scale | 加入逆变换：effectiveScale = disp.scale * cropScale | ImageEditor.ets |
| 2 | crop 无异常保护 | 整个 applyCrop 包 try-catch，失败回退 | ImageEditor.ets |
| 3 | selectCropRatio 不重置变换 | 切比例时清零 offset/scale/angle | ImageEditor.ets |
| 4 | 边把手固定比例选区跳动 | 用选区中心做居中锚点 | CropGeometry.ets |
| 5 | dispRect 重复计算 | 加缓存 dispCache + dispDirty 标记 | ImageEditor.ets |
| 6 | curPixelMap 为 undefined 时 UI 仍渲染 | 裁剪态条件加 `&& curPixelMap !== undefined` | ImageEditor.ets |

### Bug 修复

| 问题 | 根因 | 修复 |
|------|------|------|
| 裁剪结果总是原图 | applyCrop 中 pm.rotate(cropAngle) 旋转后未更新 curW/curH，region 越界 | 删除 applyCrop 中的 pm.rotate()，角度只做 UI 预览 |
| 选区外图片可见 | 图片用 Contain 全显示，无 clip | 用 Stack + .clip(true) 包裹图片在选区内 |
| 四角红点纹丝不动 | @Builder 传 number 参数不响应 @State 更新 | 删除 @Builder，改为内联组件直接引用 this.cropX 等 |
| 把手颜色改为苹果风格 | 原 #FF6B6B 红色圆形 | 改为白色 L 型角把手 + 白色细条边把手 + 白色 1.5px 框线 |
| `} else {` 编译错误 | ArkUI 声明式 UI 中 else 前多了一个 `}` | 改为两个独立 if 块 |
| 括号不平衡导致 18 个连锁错误 | 多加了一个 `}` | 删除 1030 行多余 `}` |

---

## 2026-09-10~11 编辑器全面优化（任务一~五 + A/B/C 组）

### 任务一：P0 快速 Bug 修复
1. **BusinessError 导入**：`PreferenceUtil.ets:3` 和 `MinePage.ets:8` 加 `import { BusinessError } from '@ohos.base'`
2. **ImagePreview 收藏同步**：aboutToAppear 读 isFav；收藏 onClick 改 toggleFavorite；三页面 onClose 回调刷新 favorites
3. **滤镜脏数据**：`ImageEditor.ets:445` processFilter 开头加 `const orig: Uint8Array = px.slice()`，邻居读快照

### 任务二：交互与数据正确性
1. **冷启动竞态**：Index.aboutToAppear 统一拉云数据写 AppStorage，三页面改为 @StorageProp + applyWallpapers 模式
2. **关闭动画方向**：dismiss(vertical)，下滑→dismissY=600，左滑→dismissX=-500
3. **锁屏时钟**：@State nowTick + clockTimer，startClockTicker 对齐整分钟，aboutToDisappear 清理

### 任务三：资源与性能细节
- **3-1 网络图加载后释放本地兜底图**：三页面加 remoteReady 数组 + markRemoteReady，网络图 onComplete 后隐藏本地图
- **3-2 临时文件清理**：ImageEditor 启动时 cleanupStaleFiles，loadOriginal 下载后删 dest，exportAndSave 成功/catch 清理；ImagePreview saveToAlbum 清理 preview 临时文件
- **3-3 PreferenceUtil 内存缓存**：加 favCache 数组避免每次 JSON.parse；flush 改异步不阻塞
- **3-4 注释订正**：DefaultWallpapers 数量 22→23；Wallpaper thumbnailUrl 注释修正

### 任务四：滤镜处理下放 TaskPool
- **FilterTask.ets**：20 种滤镜 + 5 种纹理全部改为 @Concurrent 函数，通过 taskpool.execute 后台执行
- **@Concurrent 限制**：函数内不得引用模块顶层 const/function，全部内联为局部变量
- **处理中遮罩**：加载态显示 LoadingProgress 遮罩

### 任务五：架构重构
- **WallpaperStore 单例**：统一首屏加载、分页游标、并发去重、空表播种、离线兜底
- **云端分页**：CloudDBUtil 新增 queryWallpaperPage(limit, offset)，首页 onReachEnd 上拉加载
- **编辑器模块化**：拆出 EditorModels.ets、EditorConstants.ets、CropGeometry.ets、FilterTask.ets、LayerGeometry.ets、ImageComposer.ets

### A 组：硬伤修复
1. **裁剪手势冲突**：裁剪态用 if 整体隐藏文字/贴纸层
2. **删除钮错位**：改为 Stack .alignContent(TopEnd) + offset，多行/英文/任意缩放都贴右上角
3. **拖出边界**：文字/贴纸 clamp 在预览区内
4. **换色不生效**：颜色圆钮点击时同步修改选中文字颜色
5. **原图高亮**：applyFilter('原图') 同步复位 filterName='原图'

### B 组：视觉与手感
1. **遮罩范围**：四条压暗遮罩按 dispRect() 图片实际范围布置
2. **最小尺寸**：固定比例拖角时短边保证 ≥60vp
3. **添加错位**：新文字按已有数量级联偏移
4. **长文换行**：Text 加 maxWidth: previewW-48

### C 组：图层跟随 + 离屏合成导出
- **C-4 图层跟随**：remapOverlays() 统一方法，裁剪/旋转/翻转后文字贴纸坐标跟随
  - 新增：`common/editor/LayerGeometry.ets` — 坐标映射纯函数
- **C-10-A 离屏导出**：OffscreenCanvas 离屏合成，原分辨率无灰边
  - 新增：`common/editor/ImageComposer.ets` — 独立 CanvasRenderingContext2D 绘制
  - 修复 ImageBitmap 不可转 PixelMap 的 API 坑（改用 OffscreenCanvas + getPixelMap）

### 后续修复（七项一次改）
1. **旋转掉色**：refreshPixelMap 保留原 PixelMap 的 pixelFormat，不再硬编码 RGBA_8888
2. **裁剪九宫格**：选区框内画 2 横 2 竖半透明白线
3. **黑白/水墨一样**：水墨重写，灰度+S曲线+边缘检测+冷灰偏色
4. **纹理太弱**：噪点 ±7%→±20%，光晕中心亮度 70→120，默认强度 50→70
5. **文字拖不动**：Stack 加 hitTestBehavior(HitTestMode.Block) 防穿透
6. **贴纸拖不动**：同文字，加 Block + 选中边框 + 缩放滑块
7. **缩放藏面板**：缩放滑块从底部面板移入元素内嵌浮层

### 预览页改造
- **ImageFit.Cover → Contain**：预览页图片完整显示，不再裁切放大
