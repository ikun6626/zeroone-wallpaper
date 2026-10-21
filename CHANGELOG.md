# ZeroOne 宠物壁纸 - 变更日志

> 所有代码改动均记录在此文件中，按时间倒序排列。

---

## 2026-10-21：首页隐藏「第 0 期」占位标题

- `HomePage.titleFor()` 过滤后台自动生成的「第 0 期 / 第0期」标题，Hero 不再展示该占位文案。
- 根因在后端：`daily-featured.service.ts` 自动创建壁纸时使用
  `每日精选 · 第 ${dto.issueNo ?? 0} 期`，issueNo 缺失即落成第 0 期。
- 后台仍待修复：创建壁纸时使用真实 issueNo（或留空），并补齐 wallpaper 1599 的 width/height 等元数据。
- `hvigor test` 通过。

---

## 2026-10-21：隐私/法律文案与线上站点对齐

- `LegalTexts.ets`：更新日期/生效日期改为 2026-10-21；明确「浏览与收藏免登录，保存图片需登录」；
  收藏注明仅本机、暂不与账号合并。`LEGAL_UPDATED_AT` 同步更新，老用户会重新看到隐私同意弹窗。
- `PrivacyConsentDialog` 概要同步新规则。
- `legal-site` 的 index/terms/about/self-check 与 README 同步：删除「不联网、零权限」「收藏跨设备同步」等过期表述；
  线上地址统一为 `https://www.gqscc.cn/legal/`，不再使用 `gqs.404.kim`。
- 核对确认：App 当前没有 Banner UI，`/api/v1/banners` 为空对用户无影响（后续启用需补空态）。
- 待运维：把 `legal-site` 部署到 `www.gqscc.cn/legal/` 并在 AGC 后台修改隐私政策 URL。

---

## 2026-10-21：保存登录门槛落地

- 三个保存入口统一接入登录门槛：预览页保存、编辑器导出、贴纸专区保存。
- 未登录点击保存：弹出既有 LoginPage/RegisterPage 覆盖层并提示「请先登录后再保存图片」；
  登录成功后回到原页面，**需要再次点击保存**（SaveButton 的相册授权按次生效）。
- 兜底拦截：`saveToAlbum()` / `exportAndSave()` / `StickerPage.save()` 内部再校验一次，防止其他调用路径绕过。
- 收藏保持游客可用，且**暂不与账号收藏合并**（按本轮决策）。
- `hvigor test` 与 `assembleHap` 均通过。

---

## 2026-10-21：贴纸专区保存模块简化

- 删除「存 JPG / 透明 PNG / 锁屏图 / 桌面图」四选一，导出面板只保留**一个保存按钮**。
- 保存统一走 JPG 到系统相册；提示改为「已保存到相册，请在系统图库中设为壁纸」。
- 导出比例选择保留（自由 / 9:16 / 1:1 / 3:4），因为它是画布构图参数，不是保存格式。
- `hvigor test` 与 `assembleHap` 均通过。

---

## 2026-10-21：产品决策定稿（PRD v0.3）

- **内容形态**：在线内容 + 本地 295 张兜底。
- **账号**：浏览免登录；**保存图片必须登录**；支持注册，沿用现有 LoginPage/RegisterPage/AuthManager；
  游客仍可浏览、收藏（本机）、编辑与贴纸创作。
- **商业化**：删除 Plus / 会员 / 支付 / 商品页，相关 UI 与市场材料全部清理。
- **主身份**：壁纸工具；编辑器与贴纸专区作为二级小创作能力保留。
- **运营**：内容、合辑、Banner、每日精选由后台管理；每天 08:30 前上架 1 张人工精选，
  必须关联 `wallpaperId` 并通过分辨率/版权审核。
- **鸿蒙限制**：三方应用不能直接设置壁纸，统一为"保存到相册 + 系统图库三步引导"，
  所有文案与市场材料不得承诺一键设置。
- **变更管理**：产品决策进 CURRENT-STATE / PRD，工程变更进 CHANGELOG，发布包版本递增，可回档。

待实现：三个保存入口的登录门槛、隐私政策/备案按联网+账号重写、Banner 空态、
每日精选第 22 期关联壁纸 1599 的 0×0/标题「第 0 期」数据修复。

---

## 2026-10-21：P0/P1 首批代码修复

### 已改

- **P0-2 首页永不空**：`HomePage` 的 Hero 在接口失败/返回空时降级到本地 295 张；
  首页分区失败时生成「本地精选」分区，不再整页黑屏。
- **P0-7 合辑计数口径**：`CategoryPage` 详情页只显示「共 N 张」，移除与副标题并排的裸数字。
- **P0-8 预览模拟层**：时钟改 12 小时制、上午/下午动态计算；删除固定假天气；桌面/锁屏时钟加半透明暗色底，浅色壁纸也可读。
- **P0-9 工具行**：收窄工具 chip 内外边距并给滚动内容预留右侧余量，6 个工具在常见机型上一屏可读。
- **P1-5 预览模式**：每次重新进入预览重置为「普通」，不再残留上次的锁屏/桌面模拟。
- **P1-7 单测**：`CropGeometry.test.ets` 补齐 `flipH/flipV` 与 `unprojectCrop` 的 `baseW/baseH` 参数，`hvigor test` 恢复全绿。
- **附带**：`LocalWallpapers.CATEGORIES` 去掉重复的「自然风景」。

### 验证

- `hvigor test` → BUILD SUCCESSFUL
- `hvigor assembleHap` → BUILD SUCCESSFUL

### 未完成（需要数据/决策，非本轮代码可定）

- P0-1：线上第 22 期虽已关联 `wallpaperId=1599`，但该壁纸 `width/height=0`、标题「第 0 期」，需后台修正并加校验。
- P0-4：隐私政策 URL 仍指向错误站点，需部署/改登记。
- P0-5：账号是否开放需产品决策（后台 auth 已就绪，App 登录入口隐藏）。
- P0-6：`/api/v1/banners` 仍为空数组，需运营补数据或 App 隐藏该区。
- P1-1 搜索、P1-2 轻编辑、P1-3 滤镜拖动性能、P1-4 收藏导出/同步，尚未实施。

---

## 2026-10-21：产品文档重建（基于 1.2.0 实际状态）

### 背景

项目先后经历「云端版 → 全离线版 → 在线+本地兜底」三次转向，根目录多份 Markdown
分别描述不同年代，导致审计与 PRD 容易引用过期事实。

### 改动

- 新增 [CURRENT-STATE.md](file:///e:/zeroone/CURRENT-STATE.md)：唯一现状基准，记录版本 1.2.0、
  在线+本地兜底形态、已完成能力、当前硬问题，以及各文档对应哪个时代。
- 重写 [USER-AUDIT.md](file:///e:/zeroone/USER-AUDIT.md)：按 1.2.0 重列用户视角 P0/P1/P2，
  新增「Hero 不可保存」「Plus 假按钮」「隐私 URL 错站」「法律文档与功能不一致」等结论。
- 重写 [PRD.md](file:///e:/zeroone/PRD.md)：主张「在线内容 + 本地兜底」，
  给出 P0/P1 验收标准、指标与需要负责人拍板的问题。

### 后台对齐（Z:\zeroone管理后台）

- 核实后台为 NestJS 12 + Prisma 6 + MySQL 8.4，模块含 `users` / `app-auth`、`daily-featured`、
  `albums`、`banners`、`stats`、`feedbacks`、`app-versions` 等。
- 修正旧结论：账号体系已在 2026-09-29 部署（此前「`/auth/login` 返回 404」是部署前状态）；
  每日精选截至 2026-10-08 已有 1–9 期（此前「第 1 期未录入」已过期）。
- `CURRENT-STATE.md` 新增后台章节，记录线上拓扑、内容规模快照（10-01：1577 张 / 13 合辑）、
  `wallpaperId` 关联要求与运维风险。

### 线上数据实测（2026-10-21）

- 公开接口：`GET /api/v1/stats` = **1598 张壁纸 / 8 个合辑**。
- 每日精选：最新第 **22** 期（2026-10-21），`wallpaperId=1599` 已关联；
  但关联壁纸 `width/height=0`、无主色/朝向、标题为「每日精选 · 第 0 期」。
- `GET /api/v1/banners` 返回**空数组**。
- 后台管理员账号存在且启用（SUPER_ADMIN）；本次提供的密码登录返回 401，需确认是否已被修改。
- 安全风险：后台仓库脚本内含明文服务器/数据库凭据，`.env` 亦含明文密钥，需立即轮换并清理。

### 规则

此后任何状态变化：先更新 CURRENT-STATE.md，再同步 PRD / CHANGELOG。

---

## 2026-10-15：上架/商户绑定 —— 产出「APP首页截图（含名称）」并定下载链接路径

### 需求

华为商户/华为支付进件的必填项：**APP下载链接** + **APP首页截图（含名称）**。
本 App 从未公开上架 → 不存在「有效且与截图一致」的下载链接（`.hap`/`.app` 直链不算，
HarmonyOS 不支持点链接安装，审核必判无效）。

### 已产出

- `e:\zeroone\APP首页截图-含名称.jpg` —— 1320×2856 JPEG / **0.28 MB**（在表单 ≤2MB 限制内）。
  来源：`截图\原生\01-首页壁纸.jpeg`（2026-10-08 由 1.2.0 构建的模拟器实机截取，**未裁切**，
  含状态栏 + 底部 Tab 栏）。1:1 裁切核验顶部「ZeroOne」名称与状态栏时钟清晰可读。
- 首页自 10-08 构建后无改动（今日仅改预览页保存逻辑）→ 截图与当前 1.2.0 一致。

### 选定路径：AGC 公开测试（最快拿到可打开的链接）

1. 本地重打 AGC 上传包（`E:\zeroone\build\outputs\default\` 下的 `.app` 已随清理删除，需重打）：
   `hvigorw assembleApp --mode module -p product=default -p buildMode=release --no-daemon`
   → 核对包内 `pack.info` 为 1002000 / 1.2.0。签名用 `default`（发布证书 zeroone.cer + fabuRelease.p7b），勿用 debug。
2. AGC → 应用测试 > 测试版本列表 > 创建测试版本 → 选**公开测试**；发布方式勾**生成分享链接**
   → 审核通过后页面给出「版本分享链接」，可直接填进进件表单（浏览器打开即可安装）。
3. 前置硬门槛（不满足必驳回）：
   - **App 备案**：审核指南明确「APP 未核准（备案）→ 先完成备案再提交审核」；
     自测报告里写的「身份证号已在华为后台校验通过」是**实名校验**，≠ 工信部 App 备案号下发。
   - **隐私政策 URL** 公网可访问且与应用内一致。

### 风险（如实）

公开测试链接属「测试专区/分享链接」，商户审核方**可能不认**为正式 APP 下载链接；
若被驳回，仍需正式上架拿 `appgallery.huawei.com` 详情页链接。

### 补充（查官方文档后）：华为支付 APP 场景要求的其实是 APPID，不是下载链接

华为支付《特约商户如何提交申请》「经营场景专项材料」原文：

- **√ APP场景** → **APPID**：需提供华为应用市场**已上架或待上架**应用的合法 APPID（AGC 可查）。
  即**不需要公开下载链接**，未上架也能进件。
- **应用截图**：含应用名称的首页截图 + **商品或服务页截图** + **支付页面截图**（共 3 张，不止首页）。
- 硬规则：**主体类型为企业时，必须填企业开发者账号注册的 APPID，不支持个人开发者账号注册的 APPID**；
  若 APPID 开发者与商户主体不一致，需 APPID 管理员做商户号关联授权 + 签《联合运营承诺函》。
- 风险：本 App 无支付/商品页，第 2、3 张截图存在提供不了的风险，需与对接客户经理确认场景是否适用。

→ 表单把「下载链接」设成必填是平台校验，与官方材料清单不一致，优先找客户经理确认能否以 APPID 替代。

### 更新（用户回复：App 已上架）

已上架 → 不必再走公开测试，直接取应用市场详情页链接即可。链接格式（官方文档 / 论坛核实）：

- `https://appgallery.huawei.com/app/detail?id={bundleName}` → 本应用 `...?id=com.zeroone.wallpaper`
- 或 `https://appgallery.huawei.com/app/C{APP ID}`（APP ID 在 AGC「项目设置 > 常规 > 应用」/ 信息中心）
- AGC 控制台「分发 / 版本信息」页也会直接给出详情页链接；手机侧：应用市场搜到应用 → 详情页 → 分享 → 复制链接

---

## 2026-10-15：全屏预览「保存」改为跟随当前显示方式（所见即所得）

### 背景（用户反馈）

> 「我明明是原图下载根本没点铺满但是还是下载的铺满效果，我想的是下面显示的铺满就相对而言放大一点，如果是适应就直接保存的原图」

### 根因（代码事实）

保存链路**完全没有读取当前显示方式**，无条件按设备屏幕比例（本机 1320×2856）裁切放大后存盘：

- 胶囊文字 = `this.fitCover ? '铺满' : '适应'`（[ImagePreview.ets#L781](file:///e:/zeroone/entry/src/main/ets/common/components/ImagePreview.ets#L781)）；
- 保存按钮却写死"固定存铺满屏幕"（[L395-399](file:///e:/zeroone/entry/src/main/ets/common/components/ImagePreview.ets#L395-L399)），
  且 `composeCanvasRatio()` 调用时**漏传 `fitMode` 参数** → 落到默认值 `FIT_MODE_COVER`
  （[ImageComposer.ets#L326-356](file:///e:/zeroone/entry/src/main/ets/common/editor/ImageComposer.ets#L326-L356)）。
- 合成函数内部**本来就实现了 contain 分支**，只是预览页从未把参数传进去。

### 改动

[ImagePreview.ets](file:///e:/zeroone/entry/src/main/ets/common/components/ImagePreview.ets)：

- `saveToAlbum()` 新增分支 `keepOriginal = !this.fitCover`：**铺满**才走 `composeCanvasRatio()` 合成；
  **适应**跳过全部合成，把已落到沙箱的源文件（云端原图 / 随包资源）`copyFileSync` 直接写入相册 —— 不裁切、不缩放、不重编码。
- 新增模块级 `detectImageExt()`：按**文件头魔数**判定 png / webp / gif / bmp，JPEG 为默认。
  （临时文件统一叫 `.jpg`，但云端原图可能被转码成 webp —— 直接按 `.jpg` 建资产会让相册解不出图）
- toast 区分「已保存 · 原图」/「已保存 · 铺满」；「设为锁屏 / 桌面」引导卡片**仅在铺满模式**弹出。
- 过期注释（"保存比例固定铺满屏幕"）全部改写。

### 验证

- `assembleHap`（release）构建成功；HAP 安装到模拟器（1320×2856）。
- **实测**：适应模式 → toast「已保存 · 原图」，4s 后**未弹**引导卡片 ✅；
  铺满模式 → 画面变为放大的裁切版，toast「已保存 · 铺满」并弹「设为锁屏壁纸」引导卡片 ✅。
- **实测**：从 App 缓存取出该壁纸云端原图 = **1280×1920（2:3）**；屏比 0.4622 → 铺满需**裁掉 30.7%**，
  超过 `COVER_CROP_TOLERANCE = 0.15`，因此默认落在「适应」—— 解释了用户"感觉被放大裁切"的由来。
- **未直接校验**：相册成图无法拉回比对（`/storage/media/**` 对 hdc shell 为 Permission denied）。
  "适应 = 原图"由代码路径保证（分支未执行合成），建议真机看一眼相册确认。
- **不受影响**：编辑页导出走 [ImageEditor.ets#L1391-1393](file:///e:/zeroone/entry/src/main/ets/common/components/ImageEditor.ets#L1391-L1393) → `composeToJpeg`，画布 = 底图原分辨率，本来就不按屏幕裁切。

### 详细方案与实施记录

见 [预览保存-跟随显示方式-方案.md](file:///e:/zeroone/预览保存-跟随显示方式-方案.md)。

---

## 2026-10-09：修复「滤镜/纹理」两个挂起 Bug（强度失灵/耗时 + 保存后花屏）

### 背景（用户反馈）

- **Bug A**：用滤镜/纹理编辑并保存后，到系统图库里看图片**花屏 / 错乱**。
- **Bug B**：滤镜模式或纹理模式下拖动「强度」滑杆，要么**处理失败**、要么**变化不大**、要么**耗时很长**。

### 根因（静态分析 + 运行时证据）

1. **强度直接失灵（Bug B 主因）**：`TaskPool` **默认「转移」ArrayBuffer 所有权**（SDK `@ohos.taskpool.d.ts` 的 `setTransferList` 注释明确说明；不调用该 API 时 ArrayBuffer 会被 transfer 且原实例失效）。
   代码把**要复用的缓存缓冲**（`baseBytesCache` 等）直接交给 `taskpool.execute`，首次调用后该缓冲即被分离，后续帧抛 `IsDetachedBuffer` → `refreshFromBase` 进 catch → 画面不更新。
   实测日志证据（修复前）：`refreshFromBase failed: name=TypeError msg=IsDetachedBuffer`。
2. **强度「变化不大」**：`runTextureTask` 里 5 种纹理中 **纸纹 / 水彩纸纹 / 噪点完全没读 `strength` 参数**；污渍用 `Math.random()`（非确定性）。
3. **保存后花屏（Bug A）**：① 纹理任务**原地修改输入缓冲**，污染了滤镜的满档缓存（缓存被写成"叠加了纹理"的脏数据）；② `readPixelsToBuffer` 的行跨距（`getBytesNumberPerRow`）可能大于 `width*4`（解码器为 SIMD 对齐做的填充），未经压紧就按 `(y*w+x)*4` 索引 → 整体错位。

### 改动

- [FilterTask.ets](file:///e:/zeroone/entry/src/main/ets/common/editor/FilterTask.ets)
  - 三个 `@Concurrent` 任务全部改为**「只读输入 + 写独立输出」**（`out` 独立分配，alpha 原样保留），不再原地写。
  - 纹理**全部按强度 k 线性混合**：`out = in + (full − in)·k`；污渍斑点改**确定性**噪声（去除 `Math.random`）。
  - 删除死代码 `runMixTask`（混合改在 UI 线程内联）。
- [ImageEditor.ets](file:///e:/zeroone/entry/src/main/ets/common/components/ImageEditor.ets)
  - 所有 `taskpool.execute` 入参改传**一次性副本** `slice(0)`，绝不交出复用缓冲。
  - 混合改为 UI 线程内联 `mixLinear`（免去每帧往返搬运 ~10MB×2 缓冲）。
  - 新增**纹理满档缓存**（`textureFullBytes/Name/Key`）+ **底图字节缓存**；`readBaseBytes()` 按行**压紧跨距**防御性修复。
  - 强度滑杆统一 `min:0, max:100, step:1`。

### 验证（模拟器 1320×2856 / release HAP，逐像素 diff）

预览区子区域（x100–1200, y500–2000）逐像素平均差：

- **滤镜强度（复古）**：0 vs 50 = 49.28、50 vs 100 = 50.15、0 vs 100 = 99.42 → 线性且单调；原图 vs 复古100 = 252 → 滤镜确实生效。
- **纹理强度（噪点）**：0 vs 50 = 4.874、50 vs 100 = 5.097、0 vs 100 = 9.940（≈两者之和），非零像素约 67% → 线性单调。
- **纹理（纸纹）**：0 vs 100 = 5.925；且**纸纹@0 与 噪点@0 预览区逐像素完全一致（mean = 0.0）** → 0% 干净回到底图。
- **导出（Bug A）**：保存后取沙箱内导出的 JPEG（临时调试副本）为 4480×6720 / q92；1:1 中心裁切**无块状、无斜切、无通道错位**，相邻像素差 H=3.72 / V=3.42（平滑）；滤镜与噪点均已入图 → **花屏已消除**。
- **性能**：单帧混合由 TaskPool 往返（debug 3–4s）降到内联（debug ≈1.8s、release ≈1.5s）。

### 说明与遗留

- 上述验证用的临时调试日志（`EDB`/`[DBG2]`）与「导出副本」代码**均已移除**，收尾后 release 构建通过。
- 遗留（**推测**，未实施）：拖动强度仍约 1.5s/帧（**模拟器本身极慢**，JPEG 编码 1280×1920 单次约 145ms 佐证）。若要真正"跟手"，需引入「拖动时低分辨率预览、松手后全分辨率重算」。

---

## 2026-10-09：贴纸工作台 + 贴纸画板「二合一」为统一「贴纸专区」

### 背景（用户反馈）

「贴纸工作台」与「贴纸画板」功能高度重叠；画板只有 3 张背景图、且 `saveBoard()` 有实现却无任何 UI 调用点，
用户感知为「画板没有保存键」。要求二合一，专门做一个「贴纸专区」。

### 改动

- **删除** `pages/StickerStudioPage.ets`（贴纸工作台，1341 行）、`pages/StickerBoardPage.ets`（贴纸画板，688 行）。
- **重写** [StickerPage.ets](file:///e:/zeroone/entry/src/main/ets/pages/StickerPage.ets)：
  由「贴纸 Tab 入口卡片列表」改为**统一编辑器本身**（一个 Tab = 一个页面文件，与 HomePage/CategoryPage/MinePage 一致），
  点「贴纸」Tab 直达，**零跳转、零覆盖层**，返回键 / 切 Tab 都不丢内容。
- 同步 [Index.ets](file:///e:/zeroone/entry/src/main/ets/pages/Index.ets) 覆盖层层级注释、
  [EditGuard.ets](file:///e:/zeroone/entry/src/main/ets/common/utils/EditGuard.ets) 注释、
  [MinePage.ets](file:///e:/zeroone/entry/src/main/ets/pages/MinePage.ets) FAQ 文案（「贴纸工作台怎么玩？」→「贴纸专区怎么玩？」）。

### 新增能力（相比原两页）

- **三步引导条**：① 选背景 › ② 贴贴纸 › ③ 导出（当前步高亮，实时显示贴纸数）。
- **统一底部工具栏**：背景 / 贴纸 / 图层 / 调整 / 导出 五个面板（可收起以最大化画布）。
- **图层列表**：贴纸由上到下 + 背景层，点击选中、一键删除。
- **撤销 / 重做**：纯数据快照（`HISTORY_MAX = 20`）+ 状态指纹同态去重 + 结构性操作截断重做尾巴。
- **贴纸分类 + 收藏**：全部 / 猫猫(31) / 狗狗(16) / 兔兔(4) / ⭐收藏，收藏持久化到 Preferences（`sticker_favorites`）。
- **背景自动衔接**：选完背景面板自动切到「贴纸」面板，引导进入第 ② 步。
- 顺手修复：内容层不再设底色，**导出透明 PNG 的 alpha 不再被 `#191A1F` 破坏**。

### 实测中发现并修复的三处打磨

1. 贴纸落位由 3×3 网格改为**对角线级联**（5 槽循环、每级 x/y 各偏移 28vp），避免前 3 张挤在同一行。
2. 图层标签由 `s.id` 改为**按列表 index**（`贴纸 ${idx + 1}`），修复撤销后跳号（原实测出现「贴纸 4 / 贴纸 5」）。
3. 空态提示容器宽 `78%` → `86%` 并精简副标题，消除「① 先选一张背景图」的尴尬折行。

### 验证

- `assembleHap`（release）构建成功；HAP 安装到模拟器（1320×2856 / density 3）。
- 逐项实测通过：Tab 直达、三步引导、选背景、加贴纸（对角线级联）、撤销、图层列表（标签不跳号）、调整面板、导出面板。
- 未能实测：真实导出到相册 / 相册选背景 —— `SaveButton` 与 `PhotoViewPicker` 属系统安全控件，不接受 `uitest` 模拟点击。
  保存代码沿用原 `StickerStudioPage` 已验证实现，未改动。

### 详细方案与实施记录

见 [贴纸专区-二合一方案与实施记录.md](file:///e:/zeroone/贴纸专区-二合一方案与实施记录.md)。

---

## 2026-10-08（发布）：新版本 1.2.0 —— 版本号提升

### 改动

- [AppScope/app.json5](file:///e:/zeroone/AppScope/app.json5#L5-L7)：`versionCode` 1000001 → **1002000**，`versionName` 1.1.0 → **1.2.0**，`buildVersion` 1 → **2**。
- [legal-site/about.html](file:///e:/zeroone/legal-site/about.html#L25)：关于页「版本：1.1.0 → **1.2.0**」（**需重新部署 legal-site 才对外生效**）。

### 本版相对 1.1.0 包含的 App 侧改动（供 AGC 更新说明）

1. 首页分区「更多 >」点击无响应修复；「我的」页统计改云端实时（2026-10-01）。
2. 图库颜色分类错跳+数量不符修复；贴纸缩放控件跟随/出框修复；「我的-最爱收藏」不展示修复（2026-10-02）。
3. 全屏预览默认显示方式改为「按机型屏幕比例自适应」（2026-10-08）。
4. 首页改用 `/home/composition`，后台「不上首页」开关生效，首页分区 12 → 8（2026-10-08）。

### 发布截图重拍（2026-10-08 23:50）

- 先把 1.2.0 构建并安装到 Pura 90 模拟器（物理 1320×2856）：产物 `entry\build\default\outputs\default\entry-default-signed.hap`（23:47，`assembleHap` 一次成功），实测模拟器版本 **versionCode 1002000 / versionName 1.2.0**（`install -r` 成功）。
- 实机逐页截取 → **等比缩放 + 居中裁剪（cover，不变形）** → 精确 **1080×1920 PNG**，同名覆盖 `截图\上传用\`；原始 1320×2856 截屏存 `截图\原生\`。
- 5 张实测（均 1080×1920、单张 ≤5MB）：

| 文件 | 体积 | 页面 |
|---|---|---|
| 01-首页壁纸.png | 1.70 MB | 首页（Hero + 分区横滚） |
| 02-合辑分类.png | 1.43 MB | 图库 Tab（**8 个合辑**网格） |
| 03-贴纸.png | 0.69 MB | 贴纸 Tab |
| 04-贴纸工作台.png | 1.94 MB | 贴纸工作台（选择背景图） |
| 05-预览页.png | 1.85 MB | 全屏预览页 |

- 复核用拼图：`截图\_新截图_预览拼图.jpg`。
- 说明：cover 裁切会同时裁掉原生上下各约 255px（状态栏与底部 Tab 栏不在图内），与 1.1.0 上架图的处理规则一致。

### AGC 上传包（.app）重建 —— 修正「上传后仍是 1.1」问题

- **现象**：上传到 AGC 的包版本显示仍是 **1.1.0 (1000001)**。
- **根因（实测）**：用户手上/已上传的那个 `.app` 是 **2026-10-08 23:35:44** 打出来的，**早于版本号提升**（`AppScope/app.json5` 改成 1002000/1.2.0 是在其后）；旧包内 `pack.info` 就是 1.1.0。之前只重建了装机用的 `.hap`，**AGC 上传用的 `.app` 一直没重建**。
- **修复**：重新执行
  `DEVECO_SDK_HOME='E:\DevEco Studio\sdk'` + `hvigorw.bat assembleApp --mode project -p product=default -p buildMode=release --no-daemon`
  → 产物 `E:\zeroone\build\outputs\default\zeroone-default-signed.app`（**2026-10-08 23:58:27**，52.93 MB）。
- **实测包内版本**：`pack.info` 与内层 `entry-default.hap/module.json` 均为 **versionCode 1002000 / versionName 1.2.0 / build 2** ✅。
- ⚠️ **上传 AGC 请用这个 23:58 的包**，不要再用 23:35 的旧包。

### 待办（发布前）

- AGC 后台填写「版本说明」文本（网页操作，不在代码内）。
- 如需随包提交自检文档，同步 [self-check.html](file:///e:/zeroone/legal-site/self-check.html) / [gen_self_check.py](file:///e:/zeroone/legal-site/gen_self_check.py) 的版本号。
- 构建：`DEVECO_SDK_HOME='E:\DevEco Studio\sdk'` → `assembleHap`（product=default，签名配置已就绪）。

> 注：后端接口/数据类改动（分区重构、摄影作品改判等）无需发版。

---

## 2026-10-08（再续）：标签/分区体系重构 · 方案 B **已落地执行**

### 背景

承接同日「标签（暗色系）与内容不符」，用户拍板 **方案 B**（首页分区收敛为「宽口径分类驱动 + `featured` 排序」）。诊断详见 [标签体系_重构方案.md](file:///Z:/zeroone管理后台/标签体系_重构方案.md)。

### 四项拍板（用户确认）

1. **方案 B**：分区一律用 `categoryIn`（人工分类）驱动 + `orderBy:"featured"`。
2. **「暗色」**：**下线 dark 分区**（算法阈值 `maxBrightness` 必然错配）+ **新建空「暗色」分类**，改由人工打标。
3. **摄影作品**：20 张（`id=19` 为 OFFLINE 不计）按内容拆入 `6 自然风景 / 1 动物萌宠 / 2 城市建筑 / 11 什锦治愈`。
4. **旧分类 & tags**：拆空/长尾旧分类（3 摄影作品 / 10 古风插画 / 5 极简风格）**保留不动**；真·`tags` 表**本轮不动**，只出方案。

### 改动（运维脚本 `Z:\zeroone管理后台\apply_home_content_fix.py`，重写为方案 B）

| 组 | 内容 | 语句数 |
|---|---|---|
| G1 | ancient 14 张 `1028–1041` → `category_id=11` | 14 |
| G4 | 7 个分区改名 + rule 改 `categoryIn+featured`；5 个分区 `enabled=0, show_on_home=0` 下线 | 12 |
| G5 | 摄影作品 20 张 → 内容分类 | 20 |
| G6 | 新建「暗色」分类（空，`kind=STYLE`） | 1 |
| G7 | `tags` 表不动（仅提示） | 0 |

- **G4 下线**：`dark` `minimal` `sunset` `photography` `ancient`；**改名**：`landscape→🏞 自然风景`、`mixed→🎨 治愈合集`、`pets→🐾 动物萌宠`、`couple→💑 人物情感`、`city→🏙 城市建筑`；`daily` 与分区顺序（`home_slot`）保持不变。
- 原 G2（12 分区 `orderBy`→featured）、G3（逐条改判建议）**已被 G4/G5 取代**。
- 只读探查证据（未入库）：`_photography_sheet.jpg`、`_dark_sheet.jpg`、`_photography_20.txt`、`_dark_candidates.txt`、`_albums_schema.txt`。

### 关键实测结论

- `brightness < 0.15 且 category_id<>8` 命中 **60 张**「暗色」候选，抽查确认绝大多数确为暗色（比旧的 `maxBrightness:0.25` 好很多；抽查 `1566` 蜘蛛侠为深蓝黑调，确算暗）。但**不做自动打标**，只作人工候选。
- 摄影作品实测实为 **21 张**（原文档写 20），其中 `id=19` 为 `OFFLINE`。

### 执行结果（2026-10-08 23:05，已写入生产库）

- 第一次执行：G1/G4/G5 共 46 条成功；G6 失败（`categories.updated_at` 无默认值）。
- 修正 G6（`INSERT ... created_at, updated_at = NOW(3)`）后二次执行成功。
- 备份：`/opt/zeroone/backup/pre-homefix-20261008-230518.sql.gz`、`pre-homefix-20261008-230551.sql.gz`。
- **核验（实测）**：
  - 上首页分区 11 → **8**：`daily, pets, landscape, city, text, anime, couple, mixed`；`dark/minimal/sunset/photography/ancient` 均 `enabled=0, show_on_home=0`。
  - 分区改名生效：`pets→🐾 动物萌宠`、`landscape→🏞 自然风景`、`city→🏙 城市建筑`、`couple→💑 人物情感`、`mixed→🎨 治愈合集`；规则全为 `{"categoryIn":[...],"orderBy":"featured"}`。
  - 分类已发布张数：`6 自然风景 525`(+9)、`1 动物萌宠 36`(+6)、`2 城市建筑 17`(+4)、`11 什锦治愈 552`(+15)、`3 摄影作品 0`、`10 古风插画 0`；新增 `12 暗色`(0)。

### 状态

- ✅ **已执行并核验**；如需回滚，用上表备份 `mysql < pre-homefix-*.sql.gz`。
- 文档更新：[首页内容层_精确清单.md](file:///e:/zeroone/截图/首页选图_实测/首页内容层_精确清单.md) 新增 §6（拍板结果 + 摄影逐张判读 + 暗色候选）与 §7（后续待办）。

---

## 2026-10-08（续）：首页内容层治理 —— 分析字段回填 + 首页编排接口 + 精确清单

### 背景

承接同日「首页图片太 low」。L2 质量闸门挡住的是**低清图**，但内容层还有**错配**：古风整册是可爱卡通、情侣混入猫狗、暗色系收亮色游戏角色、日落/留白混入静物。根因是 **2026-09-30 之后导入/爬取的 1238 张图从没跑过 `analyse_wallpapers.py`**，`dominant_color` / `brightness` 全空 → 所有按颜色/亮度定义的合辑规则（`sunset` / `dark` / `minimal`）对这些图失效。

### 改动（后端 · 数据回填，已执行）

- 新增 `backfill_analysis_missing.py`：只补「缺 `dominant_color`」行的 `dominant_color` / `brightness` / `orientation`（用 `thumb_url` 算均值；`orientation` 优先用库内 `width`/`height` 推导）。写库前自动 `mysqldump` 备份。
- **实跑 3 轮：1141 → 94 → 3 条，合计 1238/1238 全部补齐，剩 0**。备份：`pre-analysis-20261008-145347.sql.gz`、`pre-analysis-20261008-151158.sql.gz`。
- 效果（实测）：`sunset` 可用图 12 → 55；`dark` 前 8 由「粉发动漫/紫发动漫」变为真实暗色夜景。

### 改动（App 侧）

**[HomePage.ets](file:///e:/zeroone/entry/src/main/ets/pages/HomePage.ets) / [AlbumsApi.ets](file:///e:/zeroone/entry/src/main/ets/common/net/AlbumsApi.ets)**

- `loadSections()` 由 `fetchAlbumSections()`（拉 `/albums` **全量**）改为 `fetchHomeComposition()`（拉 `/home/composition`）。后端该接口按 `showOnHome` 过滤 + `homeSlot` 排序 → **后台「不上首页」开关终于生效**。
- 修复现象：`minimal`（◻️留白风景）、`photography`（📷摄影作品）后台已置 `showOnHome=false`，此前仍出现在首页；改后首页分区由 12 → 10（实测线上 `showOnHome=false` 仅这两个）。
- 删除已无调用方的 `AlbumsApi.fetchAlbumSections()`。
- 已构建验证：`assembleHap` BUILD SUCCESSFUL。

### A2 结论（原选方案被实测否定）

- 原选 `rule.orderBy: 'hot'`。实测 `download_count` 分布：**1564/1589 张 = 0，仅 25 张 > 0（最高 33）**；`hot` 并列时退回 `id desc`，**等同现有 `latest`，改了几乎不变**。
- **改选 `featured`**（`isFeatured desc → sort desc → id desc`），配合人工给好图打 `is_featured=1`（当前已有 13 张）。

### 新增运维脚本 / 文档

- `apply_home_content_fix.py`：首页内容层修正，**默认 dry-run，`--apply` 才备份+写库**。G1 = 古风整册 1028–1041 → `category_id=11`；G2 = 12 个分区 `orderBy` → `featured`；G3（`--with-proposals`，未拍板）= 逐条改判/下架清单。
- [首页内容层_精确清单.md](file:///e:/zeroone/截图/首页选图_实测/首页内容层_精确清单.md)：逐分区精确 id + 建议动作 + 实测 contact sheet。
- 删除已废弃的 `set_home_sections_hot.py`（hot 方案被实测否定，由 `apply_home_content_fix.py` 的 G2 取代）。

> ⚠️ G1/G2/G3 均**尚未执行**，待用户最终确认；执行前会先 `mysqldump` 备份到 `/opt/zeroone/backup/`。

---

## 2026-10-08 优化：首页分区只收高清图（L2 质量闸门）+ 全量实测 bug 清单

### 背景

用户反馈「首页图片太 low」。实测定位根因：首页分区取合辑前 8 张、默认 `publishedAt desc` → **最新导入的低质批次排最前**。实测分辨率：宠物前 12 张长边≤1080（含 350×260 / 500×375，即截图中糊掉的狗 id 347/346/345）；日落与夜色 60/60 = 498×1080（多张 13–30KB）；暗色系前 16 张多为 498×1080。

### 改动（App 侧）

**[AlbumsApi.ets](file:///E:/zeroone/entry/src/main/ets/common/net/AlbumsApi.ets)**

- `fetchAlbumPage` 新增 `minLongEdge` / `minShortEdge` 参数：>0 时拼到查询串（后端按「长边≥minLong 且 短边≥minShort」过滤低清图）。传 0 表示不过滤（合辑详情页保持完整运营序）。

**[HomePage.ets](file:///E:/zeroone/entry/src/main/ets/pages/HomePage.ets)**

- `loadSectionItems` 改为 `fetchAlbumPage(slug, 1, 16, '', 1440, 900)`：首页分区只收高清图。

### 改动（后端，`Z:\zeroone管理后台\backend`，已部署）

- 新增 `src/common/utils/image-size.ts`：纯 JS 图片头解析（JPEG SOF / PNG IHDR / GIF / BMP / WEBP），无第三方依赖，解析失败返 null。
- `src/storage/storage.service.ts`：新增 `readLocalFile(keyOrUrl)`（本地驱动读文件）。
- `src/modules/wallpapers/wallpapers.service.ts`：`create/update` 增加入库分辨率校验（`assertResolution`，宽高均 >0 才校验）；本地文件兜底探测补写 width/height/orientation。
- `src/config/configuration.ts`：storage 段新增 `minLongEdge`(1440) / `minShortEdge`(900)。
- `src/modules/albums/albums.service.ts`：`resolveAlbum` 增加 `quality` 闸门参数，**对手工项与自动项一并过滤**（仅首页分区带参数时生效，详情页不带 → 保留完整运营序）。
- `src/modules/albums/albums.controller.ts`：`detail()` 解析 `minLongEdge` / `minShortEdge` 传给 service。
- 新增 `scripts/backfill-image-size.js`：扫描 `(width=0 OR height=0)` 记录，读文件头回填宽高与朝向（dry-run 可预演）。

### 回填与部署

- 回填已实跑：`1240/1240` 全部成功，剩 1 条 `id=349` 已下架（OFFLINE）正确跳过。
- 已部署（`deploy_stage1_upload.py` + `deploy_backend_targeted.py`），重建后路由 401 验证通过。
- 线上验证（闸门前→后）：宠物 `350×260`→`1440×961`、日落 `497×1080`→`1440×960`、城市剔除 `1440×810`、文字剔除 `888×1920`；暗色/治愈/动漫/综合本就达标无副作用。带闸门返回共 64 条，**不合格 0 条**。
- App 已重建（`assembleHap` BUILD SUCCESSFUL 46s）+ 重装模拟器，首页实测：宠物分区清晰高清、日落/城市/治愈分区无糊图。

### 实测 bug 清单（全量实测 Agent，严重度排序）

| # | 严重度 | 现象 | 复现 | 处置 |
|---|---|---|---|---|
| 1 | 严重 | 全屏预览页**无法上下滑切换图片**；左右滑会退出预览返回列表 | 图库→合辑→点首图→预览→上下 swipe 图片不变；左右 swipe 退回列表 | ✅已修（改左右滑切图 + 下滑关闭，实测通过） |
| 2 | 中 | 给定测试账号登录失败：提示「用户名或密码错误」 | 我的→登录→填 3237145490 / gtt990427 | ✅非缺陷（服务器 users 表仅 5 条，无该账号，提示正确） |
| 3 | 中 | `/albums` 的 `count` 与 `/albums/{slug}` 的 `total` 不一致（治愈风景 516 vs 300） | 只读接口对比 | ✅已修+已部署（线上 12 合辑全部一致） |
| 4 | 中 | 跨合辑大量重复图：日落∩留白约 29 张；「星夜孤树」同时是每日精选内容/暗色封面/留白内容；全量 39 张跨合辑重复 | 只读接口去重统计 | ⛔不改（见下方结论） |
| 5 | 中 | 冷启动/回前台首屏**无骨架屏、空白约 2–4 秒** | 冷启动后立刻截图 | ✅已修（真因是启动窗口白屏，非缺骨架屏） |
| 6 | 中 | 每日精选命名不一致：9 项中 6 项「第 N 期」、2 项「今日精选」、1 项「今日精选·星夜孤树」 | 只读接口 | ✅已修+已部署（9 期统一「第 1–9 期」） |
| 7 | 轻微 | 贴纸工作台连续添加贴纸默认叠在**同一中心位置**（互相重叠） | 工作台→连点贴纸库两张 | ✅已修（按 3×3 网格依次落位） |
| 8 | 轻微 | 贴纸可被**拖出白色保存框之外**，无边界限制 | 工作台→拖贴纸到画布外 | ✅已修（拖动夹紧在画布内） |
| 9 | 轻微 | 贴纸画板初始**画布纯黑、无空态引导** | 贴纸→贴纸画板 | ✅已修（真因：背景资源已删，见下） |
| 10 | 轻微 | 登录弹窗密码框右侧出现**两个「眼睛」图标**（重复/错位） | 我的→登录/注册 | ✅已修（关掉系统自带小眼睛） |
| 11 | 轻微 | 登录弹窗副标题与背景页文案**透出叠字** | 我的→登录/注册 | ✅已修（补不透明底色 + 提对比度） |
| 12 | 轻微 | **退出登录无二次确认** | 账号设置→退出登录 | ✅已修（showDialog 二次确认） |
| 13 | 轻微 | 筛选色卡命名怪异（「黄绿」「橙黄」）含义不易理解 | 合辑详情顶部筛选条 | ✅已修（chip 加色块圆点，名称与筛选参数不变，实测通过） |

### 修复记录（同日续修，逐条含真因）

**#1 预览页不能滑动切图｜严重**
- 真因：`ImagePreview` 只注册了 `PanGesture` 做「下滑关闭」，水平方向没有消费者；列表侧也没有相邻项取数能力。
- 改动：[ImagePreview.ets](file:///E:/zeroone/entry/src/main/ets/common/components/ImagePreview.ets) 增加内部 `@State cur`（首帧 = 入参 `wallpaper`），新增 `neighbor` 回调 props 与 `goNeighbor(dir)`；未放大时按主轴分流 —— 水平拖 = 切图（`switchDx` 跟手 + 旧图滑出/新图滑入），垂直拖 = 下滑关闭（`dismissY` 只响应向下）。到头 toast「已经是第一张/最后一张」。
- 调用方补齐 `neighborOf()`：[CategoryPage.ets](file:///E:/zeroone/entry/src/main/ets/pages/CategoryPage.ets)（`items`）、[HomePage.ets](file:///E:/zeroone/entry/src/main/ets/pages/HomePage.ets)（Hero + 各分区按 id 去重）、[MinePage.ets](file:///E:/zeroone/entry/src/main/ets/pages/MinePage.ets)（`favWallpapers`）。
- 实测（模拟器 127.0.0.1:5555）：左滑切到第 2 张、右滑回第 1 张、第 1 张再右滑提示「已经是第一张」且不退出、下滑正常退出、返回后 Tab 栏恢复。
- 注意：`saveToAlbum` 里 `Resource | undefined` 需先赋给局部 `const` 再判空，否则 ArkTS 联合类型不收窄、重载解析失败（本次踩过）。

**#3 合辑张数口径不一致｜中｜已部署**
- 真因：`listForApp` 的 `count` 用的是**未截断**的行数，而详情 `total` 用的是被 `limitCount` 截断后的 rows。
- 改动：[albums.service.ts](file:///Z:/zeroone管理后台/backend/src/modules/albums/albums.service.ts) 的 `resolveAlbum` 返回类型由 `{rows,count}` 改为 `WallRow[]`（方法内已 `slice(0, limit)`），`listForApp` 的 count 与 `detailForApp` 的 total 都取该数组长度。
- 线上复验：12 个合辑 `count == detail_total` 全部一致（修复前 landscape 516/300、dark 1288/60、minimal 402/60、sunset 61/60 四处不一致）。

**#4 跨合辑重复图｜中｜结论：不改**
- 现状实测：出现 1543 次、唯一 1416、重复 127；跨 ≥2 合辑的壁纸 126 张。主要重叠：`landscape∩minimal = 60`（留白风景 60 张是治愈风景的子集）、`dark∩mixed = 51`、`landscape∩sunset = 12`。
- 结论：合辑是同一图池上的**不同策展视图**（治愈风景 ⊃ 留白风景本就是子集设计），重叠不等于缺陷；且首页 HomePage 已用 `seenUrls` 跨分区去重，**用户可见的首页没有重复**。故不改代码。

**#5 冷启动首屏空白｜中**
- 真因（实测纠正）：不是缺骨架屏 —— Hero 与各分区本来就都有骨架屏。真正原因是 `resources/base/element/color.json` 的 `start_window_background = #FFFFFF`，且 App 未强制深色；**浅色系统下冷启动会先闪一屏纯白**（实测 0.5s 截图即白屏），同时状态栏也白底黑字压黑色内容。
- 改动：base 的 `start_window_background` 改 `#000000`；[EntryAbility.ets](file:///E:/zeroone/entry/src/main/ets/entryability/EntryAbility.ets) 的 `setColorMode` 由 `COLOR_MODE_NOT_SET` 改 `COLOR_MODE_DARK`（本 App 是「高级黑」单主题）。
- 实测：冷启动 0.4s 截图已是黑底白图标（启动窗无缝衔接），状态栏图标转白。

**#6 每日精选命名不统一｜中｜已部署**
- 真因：DTO 文档写「留空则 App 用默认"今日精选"」，但代码兜底早已改成「第 N 期」，两处漂移；前 3 期存了历史运营标题。
- 改动：生产库执行 `UPDATE daily_featured SET title='' WHERE title <> '' AND title NOT LIKE '第 % 期';`（影响 3 行）；[daily-featured.dto.ts](file:///Z:/zeroone管理后台/backend/src/modules/daily-featured/dto/daily-featured.dto.ts) 描述同步修正。
- 线上复验：9 期全部为「第 1–9 期」，副标题保留。

**#7 贴纸叠在同一中心点｜轻微**
- [StickerStudioPage.ets](file:///E:/zeroone/entry/src/main/ets/pages/StickerStudioPage.ets) 的 `addSticker`：原 `(len % 5) * 18 - 36` 步长仅 18vp、5 个就绕回原点；改为按 3×3 网格（`(k%3-1)*46`, `(⌊k/3⌋%3-1)*46`）依次落位。

**#8 贴纸可拖出保存框｜轻微**
- 同文件 `StickerNode` 的 `PanGesture.onActionUpdate` 增加 `clampX/clampY`：把贴纸**中心**夹在画布内（留 12vp 边距），允许边缘出血但保证还能被抓回来。

**#9 贴纸画板初始纯黑｜轻微**
- 真因：`StickerBoardPage.bgs` 指向 `default_wallpaper_01/03/07`，而这些资源**已随 `DefaultWallpapers` 清理被删除**（git 记录为 `D`），`$r('app.media.…')` 运行期解析不到 → 画布只剩 `#222222` 底色，看起来「纯黑」。
- 改动：`bgs` 改为工程内真实存在的 `wp_pexels_ocean_1867285` / `wp_jofy88_fall_1051300` / `wp_pexels_astronomy_1850461`；并补空态引导「还没有贴纸／点下方「贴纸」挑一张，拖动即可摆放」（放在 `boardRoot` 之外，不进快照）。
- 实测：画板显示海面日落底图 + 空态引导。

**#10 密码框两个「眼睛」｜轻微**
- 真因：`InputType.Password` 时系统自带的密码可见性图标 + 本页自绘的 `👁` 文本同时出现。
- 改动：[LoginPage.ets](file:///E:/zeroone/entry/src/main/ets/pages/LoginPage.ets) 与 [RegisterPage.ets](file:///E:/zeroone/entry/src/main/ets/pages/RegisterPage.ets) 给密码框加 `.showPasswordIcon(false)`（注册页两个密码框都加了）。
- 实测：仅剩一个眼睛图标。

**#11 登录页叠字｜轻微**
- 真因：① 青蛙 GIF 解码完成前 `Image` 不占像素，背后「我的」页文字直接透上来；② 副标题与底部文案用 `#CC264653`（深青）压在 GIF 上，对比度极低，看起来像幽灵叠加字。
- 改动：两页 Stack 首层加不透明底色 `COLOR_DEEP`；副标题与「还没有账号？/已有账号？」改 `#CCFFFFFF`。
- 实测：背景完整覆盖、副标题清晰可读。

**#12 退出登录无二次确认｜轻微**
- 改动：[AccountPage.ets](file:///E:/zeroone/entry/src/main/ets/common/components/AccountPage.ets) 新增 `confirmLogout()`，用 `promptAction.showDialog` 二次确认（与「注销账号」提示等级对齐）。原 `MinePage.onLogout()` 无调用点，属死代码，未改。

**#13 色卡命名｜轻微｜已修（展示层加色块圆点）**
- 现状色桶（源头 `analyse_wallpapers.py`）：红/橙黄/黄绿/绿/青/蓝/紫/粉/灰。「橙黄」(hue 15–45)、「黄绿」(45–70) 是标准色名但不够直观。
- 产品口径（用户选定）：**仅改展示层** —— chip 里在色名左侧并排画一个色块圆点，把「这个颜色到底长什么样」直接摆出来；**色名与 `?color=` 参数保持原值不变**（不动后端、不动生产库 `dominant_color`）。
- 改动：[CategoryPage.ets](file:///E:/zeroone/entry/src/main/ets/pages/CategoryPage.ets) 新增 `colorDotHex(name)` 色名→色值映射（红/橙黄/黄绿/绿/青/蓝/紫/粉/灰 → 统一色板，未知兜底灰）；颜色 chip 由纯 `Text(c.color)` 改为 `Row({space:6}){ 10vp 圆点 + Text }`，外层 padding/圆角/选中态（红底）不动，`ForEach` key 仍为 `c.color`。
- 实测（模拟器 127.0.0.1:5555，图库→治愈风景）：顶部筛选条依次显示「全部(红底选中) / 蓝·青·绿·黄绿·橙黄」各带同色圆点，筛选逻辑与计数不受影响。

### 验证正常（供参考）

图库颜色筛选正确（治愈风景 300→蓝 21）；预览单击切换工具栏；SaveButton 保存到相册成功并弹「已保存到相册✅」；收藏心形可用且计数一致；贴纸工作台全链路可用；返回时对未保存编辑有「放弃编辑?」确认；登录弹窗可「跳过」游客浏览；首页 Hero 左右滑切换正常；分区「更多>」跳转正确。

---

## 2026-10-08 优化：全屏预览默认显示方式改为「按机型屏幕比例自适应」

### 背景

用户反馈「壁纸全屏预览页图片显示太大」。定位后确认：`ImagePreview` 的默认显示策略是 `fitCover`（Cover 铺满），只有 `w > h`（横图）才会自动切成 Contain。而 Cover 在细长屏上会把图等比放大并裁掉两侧 —— 例如第 9 期（原图 1280×1920，r=0.667）放到模拟器 1320×2856（预览区 r=0.504）上，会被放大 1.49 倍、**横向裁掉约 24.5%**，观感就是"图太大 / 两侧被裁"。

### 改动

**[ImagePreview.ets](file:///E:/zeroone/entry/src/main/ets/common/components/ImagePreview.ets)**

- 新增模块级常量 `COVER_CROP_TOLERANCE = 0.15`：铺满允许裁掉的最大图片比例（可调）。
- 新增 `containerRatio()`：取预览区宽高比，优先用 `onAreaChange` 记录的实际尺寸，未就绪时退回 `display.getDefaultDisplaySync()` 的屏幕比例兜底 —— 因此**同一张图在不同屏幕比例的机型上会得到不同结论**。
- 新增 `decideFitCover(w, h)`：铺满必然裁掉一部分图，裁切比例 `= 1 - min(屏比, 图比) / max(屏比, 图比)`；≤ 阈值就用「铺满」，否则用「适应」完整显示。
- `onInfo` 由原来的「只有横图才切 Contain」改为调用 `decideFitCover`。
- `fitDefaulted` 改为 `userTouchedFit`：用户手动点过「铺满/适应」后，后续图片回调不再自动覆盖其选择（原实现里用户先点、`onInfo` 后到会被改回去）。

**[RemoteImage.ets](file:///E:/zeroone/entry/src/main/ets/common/components/RemoteImage.ets)**

- 补一条隐患：`onInfo` 原本只在**远程图**加载成功后回调，纯本地图（`url` 为空）永远拿不到尺寸、无法按比例决策，横图本地图会被错误铺满。现在本地兜底 `Image` 加 `onComplete`，在 `url` 为空时用源尺寸补一次 `onInfo`。

### 实测（模拟器 127.0.0.1:5555，预览区 r≈0.504，非推测）

| 图 | 原始尺寸 | 图比例 | Cover 裁切 | 打开后默认 |
|---|---|---|---|---|
| 第 9 期（竖图） | 1280×1920（实下原图确认） | 0.667 | 24.5% | **适应**（完整显示，上下黑边） |
| 摄影作品 id36 | 960×1920 | 0.500 | 0.7% | **铺满**（贴近屏比，铺满自然） |
| 宠物·横图 | 350×260 等 | ≥1.25 | ≥63% | 适应 |

手动「铺满 / 适应」切换仍正常（点后立即生效）；远程链路改动后回归第 9 期仍为「适应」，无闪退。

---

## 2026-10-02 修复：图库颜色分类错跳+数量不符 / 贴纸缩放控件不跟随且超框 / 我的-最爱收藏不展示

### 背景

用户反馈 3 个 Bug：① 图库点颜色分类会自动跳转到「治愈风景」，且顶端数量与实际展出壁纸数不符；② 贴纸画板选择贴纸后放大缩小，缩放控件不跟随且超出边框；③ 我的-最爱收藏不展示已收藏壁纸。三者均已修复并在 Pura 90 模拟器（1320×2856，真实 density=3.5）实测通过。

### Bug1：图库点颜色分类错跳治愈风景 + 数量不符

**根因**:[CategoryPage.ets](file:///E:/zeroone/entry/src/main/ets/pages/CategoryPage.ets) 的 `pickColor` 里残留了一段「点任意颜色都跳到治愈风景合辑」的兜底分支；列表页顶部还渲染了与详情页重复的 colorChips。数量不符则是因为头部计数直接用当前列表 `items.length`，加载/筛选切换瞬间只反映已加载条数。

改动：列表页移除 colorChips；`pickColor` 删除跳治愈风景分支；新增 `@State totalNum`,`loadPage` 中 `totalNum = page.total>0 ? page.total : totalNum`（total 为 0 时保留上次值），`openAlbum/closeAlbum/pickColor` 重置为 0；头部计数改为 `totalNum>0 ? totalNum : items.length`。

**实测**：治愈风景显示 300 与实际一致；点红色筛选显示 4 与展出 4 张一致，且不再跳转到治愈风景。

### Bug2：贴纸缩放控件不跟随且超出边框（画板 + 工作台同源）

**根因（关键发现）**：ArkUI 的 `.transform(matrix4)` 矩阵坐标原点是**组件中心**，而非此前以为的左上角。旧实现把「绕中心缩放/旋转 + 中心补偿平移」全部塞进矩阵（并用纯矩阵 translate，其单位还是 px),与框架的中心原点约定冲突，导致缩放时贴纸持续漂移、滑杆定位随之错乱甚至超出边框。

最终修复采用**职责分离**：

- 位置用 `.offset({x, y})`（vp）表达；`.transform()` 只做绕中心的 scale / rotate。
- [StickerBoardPage.ets](file:///E:/zeroone/entry/src/main/ets/pages/StickerBoardPage.ets)：StickerNode 改为 `.offset({x:posX,y:posY})` + 纯缩放旋转矩阵；删除失效的 onAreaChange/boardW/boardH，改用 `componentUtils.getRectangleById('boardRoot')` 命令式实时查尺寸（px÷density）供滑杆定位；滑杆 Row 用 `stickerSliderX/Y(transformTick)` 跟随贴纸，半包围按 `70*zoom*(|cosθ|+|sinθ|)` 计算。
- [StickerStudioPage.ets](file:///E:/zeroone/entry/src/main/ets/pages/StickerStudioPage.ets)：同源修复 StickerNode（offset + 纯缩放旋转）；背景矩阵简化为只 scale，背景 Image 用独立 offset；移除 CanvasSpec import。
- 新增/接通 `transformTick` 版本号：贴纸 item 是 @Observed，改其属性只刷新 @ObjectLink 的 StickerNode，父组件里依赖贴纸位置/大小的滑杆定位读不到变化。画板原本已有该机制；工作台此前 `onDirty` 是空实现，本轮补上自增 tick，`onSelectedScaleChange` 也自增，`stickerSliderY()` 读 tick 重算——滑杆现可垂直跟随贴纸底部（工作台滑杆为水平居中的既有设计），且有 clamp 不超边框。

**实测（非推测）**：画板 zoom 1→2.8，贴纸真实中心恒定 **(975,1647) 物理 px** 不再漂移，滑杆值同步、完整位于画板底部；工作台放大到约 2 倍滑杆从 y=1100 跟随下移到 y=1344（底部 1484 < 白框 1516），缩小到 0.7 回落到 y=1013；贴纸中心在 s=0.7 与 s=1 间相差 <3vp（在虚线判读误差内）。
（注：排查中确认 `componentUtils` 的纯矩阵 `transformPoint` 只做矩阵运算、不反映 ArkUI 渲染的中心原点约定；dumpLayout 对被 clip 的 transform 组件 bounds 会误报，定位中心以小 zoom 截图为准。）

### Bug3：我的-最爱收藏不展示已收藏壁纸

此 Bug 由「后端分页永远返回第 1 页」+「App 收藏快照无法还原成真实壁纸」两部分叠加造成。

**后端根因**：全局 `ValidationPipe` 开启了 whitelist，会剥离 DTO 上没有装饰器的未知属性。[app-api.service.ts](file:///Z:/zeroone管理后台/backend/src/modules/app-api.service.ts) 的 `AppWallpaperQuery` 里 `page/pageSize/...` 等字段缺少完整装饰器，被当未知字段剥离 → 分页参数恒为默认第 1 页。给所有字段补齐 `@IsOptional @Type(()=>Number) @IsInt` 等装饰器后分页恢复。[albums.service.ts](file:///Z:/zeroone管理后台/backend/src/modules/albums/albums.service.ts) daily 分支另补了批量查 description 并回填到 item。（详见管理后台 DEPLOY-NOTES.md。）

**App 改动**：

- [PreferenceUtil.ets](file:///E:/zeroone/entry/src/main/ets/common/utils/PreferenceUtil.ets)：新增 `KEY_FAV_ITEMS='favorite_items_v1'`、`toggleFavoriteItem(id, item?)`（`c_<serverId>` 别名归一 + 快照登记 + 广播）、`getFavoriteItems()` 逐字段重建真实 Wallpaper 实例。
- [AlbumsApi.ets](file:///E:/zeroone/entry/src/main/ets/common/net/AlbumsApi.ets)：ApiAlbumItem 加 description；`toWallpaper` 的 id 规则改为 `desc.length>0 ? desc : (a.id>0 ? c_<id> : daily_<issueNo>)`。
- [MinePage.ets](file:///E:/zeroone/entry/src/main/ets/pages/MinePage.ets)：`rebuildFavorites` 改为 catalog→快照双源兜底、`findByIdIn`（含 c_ 别名）、sameIds 内容一致则跳过赋值（修复给 @StorageProp 赋新数组触发 @Watch 无限递归栈溢出的闪退）；`onVisibleAreaChange` 加 rebuildFavorites；收藏数 3 处统一改为 favWallpapers.length。
- [ImagePreview.ets](file:///E:/zeroone/entry/src/main/ets/common/components/ImagePreview.ets)：收藏改用 toggleFavoriteItem。

**实测**：预览点心形收藏（心形变红）→ 我的页收藏数实时 +1 → 最爱收藏列表展示对应壁纸；点列表红心取消收藏，数量与列表实时减少。修复前后端分页 curl 验证 page=2 正确返回 id=1575。

### 产出

- AGC 上传包：`e:\zeroone\build\outputs\default\zeroone-default-signed.app`。

---

## 2026-10-01（中午）修复：今日精选无法保存 + 合辑接口物化缓存性能优化（管理后台提速 5 倍）

### 背景

用户反馈管理后台整体延迟高，且「今日精选」新增图片一直保存失败（实测用 1280×1920、3.7MB 竖图 `wallhaven-pomg5p_1280x1920.png`)。经服务器实测取证，定位为一个确定性校验 Bug + 合辑 N+1 查询放大，两者都已修复上线。

### 修复 1：今日精选 date 字段必定 400（整行存不进）

**根因（有实测证据）**:`daily-featured.dto.ts` 的 `date` 字段使用 `@IsDate()`，但**缺少 `@Type(() => Date)`**。前端表单选日期后提交的是字符串（`YYYY-MM-DD HH:mm:ss` 或 ISO),class-validator 要求 Date 实例 → 直接 400「date must be a Date instance」，导致整期精选存不进。

| 文件 | 改动 |
|---|---|
| 后端 `daily-featured/dto/daily-featured.dto.ts` | `date` 字段加 `@Type(() => Date)`，字符串与 ISO 两种日期均可正确转 Date 存入 |
| 后端 `daily-featured/daily-featured.service.ts` | `create()` 手填期号冲突时先查重，抛 **400**「第 X 期已存在，请改填其他期号或留空自动编号」（原来直接炸 500 唯一约束错误）;`update()` 冲突错误从裸 `Error` 改为 `BadRequestException` |
| 前端 `pages/daily-featured.tsx` | 日期选择器加显式 `transform`:dayjs → ISO 字符串（空值不发该字段）；上传提示从过时的「建议 750×400 或更宽」改为「竖图最佳 · 建议 1080×1920」；副标题占位/默认提示从宠物主题文案改为「每天精选一张好壁纸」 |

### 修复 2：合辑接口 N+1 查询 → 物化数据集 + 15 秒缓存（核心性能优化）

**原问题**:`albums.service.ts` 对每个合辑（13 个）分别跑多条 SQL（封面候选 + 计数 + 内容），App 首页一轮分区请求产生 50+ 条 SQL;`/api/v1/albums`、`/api/v1/home/composition` 真实延迟约 200–270ms。曾尝试 `Promise.all` 并行化，但服务器单核，并行抢同一 CPU 无效——真正的解法是**减少查询数量**。

重构方案（[albums.service.ts](file:///Z:/zeroone管理后台/backend/src/modules/albums/albums.service.ts)):

1. **物化数据集**：`loadMaterial()` 一次查全量已发布壁纸（含标签）+ 全量 albumWallpaper 关联；15 秒 TTL 内存缓存 + singleflight（并发请求只查一次）。
2. **内存规则引擎**:`matchRule()`（与旧 SQL `buildWhere` 语义一致）、`compareRows()`（与旧 `orderOf` 一致）、`resolveAlbum()`（手工置顶 + 规则自动装填 + 去重截断）。
3. `listForApp()`、`detailForApp()` 全部基于物化数据集内存计算；详情分页后只对当前页 ID 补一次全字段查询；daily 源合辑保留单独查 `daily_featured` 的特例。
4. **所有写方法**（create/update/remove/addItems/removeItems/reorder）均调用 `invalidateMaterial()`，写后立即失效缓存。
5. 顺手修正旧实现计数 Bug:`count` 取手工/自动并集去重（原来 manualCount + autoCount 重复计数）；删除无调用的旧方法 countOf/pickCoverCandidates/pickCover。
6. 接口返回结构保持兼容（普通合辑详情项为完整壁纸行，含 thumbUrl/imageUrl/category/tags 等 App 使用的全部字段）。

### 延迟真相（重要纠偏：本机 Clash 代理导致误判）

此前测出接口"约 1 秒"的延迟是**假象**——Python requests 默认读取系统 `https_proxy=http://127.0.0.1:7897`（本机 Clash)，请求绕了代理。绕过代理（`trust_env=False`）后实测：

| 接口 | 优化前真实延迟 | 优化后实测 |
|---|---|---|
| `/api/v1/albums`（暖缓存） | ~240ms | **44–48ms** |
| `/api/v1/home/composition` | ~250ms | **45–92ms** |
| 12 个分区详情全并发（总墙钟） | 数秒 | **255ms**（单项 180–249ms） |
| 其余管理端列表接口 | 40–60ms | 38–60ms |

### 验证（实测，非推测）

- 全功能 API 烟测：profile / stats / wallpapers / categories / tags / albums / daily-featured / banners / notices / feedbacks / users / app-versions 全部 200；banner 新建→编辑→删除写闭环正常。
- 今日精选完整闭环：真实文件上传 `/admin/upload`（3.7MB 直连 7.8s，HTTP 201)→ 以 ISO 日期字符串 POST 创建（HTTP 201，第 2 期）→ 管理后台列表两期均显示 → App 端 `/api/v1/daily/featured` 与 `/api/v1/albums/daily` 均返回新期为第一项。
- Pura 90 模拟器（1320×2856）**冷启动**实测：首页 Hero Swiper 显示「**10月1日 星期四 · 第 2 期**」及该图（与原图逐像素一致）。
- 浏览器内直接上传大文件会被本机 Clash 代理拦截（60s ERR_ABORTED)，绕过代理直连正常——属本地网络环境问题，非应用缺陷。
- App 端代码本轮未改，接口契约兼容，**最终 AGC 包无需因本轮重打**。

---

## 2026-10-01（上午）修复：首页分区「更多 >」点击无响应 + 「我的」页统计改云端实时 + 后台账号设置

### 背景

用户反馈首页各分区标题旁的「更多 >」点击无反应。排查确认分区头**原本完全没有绑定 onClick**（功能从未实现），需要补通「首页分区 → 图库对应合辑详情」的跳转。

### 根因与踩坑（关键：不可见 TabContent 的状态回调被冻结）

应用无 router/Navigation，四个页签是 `Tabs` + 状态切换。最初给图库页（CategoryPage）用父子下发的方式接收跳转请求，连续两版均失败，最终通过实机 hilog 取证定位：

1. **@Prop + @Watch**：首页点击时同一帧内「写请求值 + 切到图库 tab」，图库页此刻不可见，**@Watch 不被投递**；延后一个事件循环读取也无效。
2. **@StorageProp + @Watch（AppStorage 事件总线）**：仍然不触发。
3. 结论：**ArkUI 会冻结不可见 TabContent 中的组件，@Prop/@StorageProp 的 @Watch 在后台一律不投递**，显示后也不补投。

### 最终方案：事件总线 + 子页可见时主动拉取

| 文件 | 改动 |
|---|---|
| `common/net/ApiConfig.ets` | 新增 AppStorage 键 `APP_KEY_OPEN_ALBUM = 'openAlbumReq'` |
| `pages/HomePage.ets` | 新增 `onMore: (slug: string) => void` 属性；分区头「更多 >」绑定 onClick（触感反馈 + 回调 slug），并加 padding 扩大触摸热区 |
| `pages/Index.ets` | onMore 回调：自增序号 → 写 `AppStorage`（值为「序号:slug」）→ 切到图库 tab（先写总线再切换，保证子页可见时值已落定） |
| `pages/CategoryPage.ets` | 移除全部 @Watch；根容器加 `onVisibleAreaChange`，每次图库页变为可见时调用 `onPageBecameVisible()`：主动 `AppStorage.get` 拉取请求，`lastHandledReq` 去重，解析出 slug 存入 `waitingSlug`；列表未加载完时排队，`loadAlbums` 成功/兜底/异常三分支尾部统一 `tryOpenWaiting()` 补打开 |

「序号」保证连续点同一合辑也能重复响应；首页分区与图库合辑 slug 同源（`fetchAlbumSections` 内部调 `fetchAlbums`），匹配可靠。

### 验证

Pura 90 模拟器（1320×2856）冷启动实测：首页加载后**首次点击**「更多 >」即切到图库并直接打开「宠物」合辑详情（20 张壁纸），无需点第二下。调试日志已全部移除，最终 release 包复验通过。

- 最终产物：`E:\zeroone\build\outputs\default\zeroone-default-signed.app`（约 55.57 MB，2026-10-01 09:57 重新构建，含本修复）。

### 「我的」页统计卡：本地写死 → 云端实时统计

用户指出统计卡（截图：315 张壁纸 / 5 个分类 / 0 个收藏）前两个数是本地内置兜底目录的数
（`allWallpapers.length`、`LocalWallpapers.CATEGORIES.length-1`），后台继续上图它也不变，
要求删除或实时统计——采用实时统计。

| 文件 | 改动 |
|---|---|
| 后端 `modules/app/app-api.service.ts` / `.controller.ts` | 新增 `GET /api/v1/stats`（@Public）：直接数表返回已发布壁纸数 + 启用合辑数，并行查询；不用合辑 count 相加（一张壁纸可命中多个规则合辑、daily 引用已有壁纸，相加会重复） |
| `common/net/AlbumsApi.ets` | 新增 `AppStats` 类、`fetchStats()`（失败返回 null） |
| `common/net/ApiConfig.ets` | `PATH.STATS = '/stats'` |
| `pages/MinePage.ets` | 新增字符串状态 `wallpaperNumText`/`albumNumText`（初始 `--`）；根容器 `onVisibleAreaChange` 每次进「我的」即拉取，成功才覆盖、失败保持 `--`（不回退本地数）；标签「个分类」改「个合辑」 |

踩坑：统计 chip 最初用 `@Builder statChip(icon, num, label)` 把数字当按值参数传入，
**状态变化后 chip 不刷新**；同页直接引用状态的 Text 正常。最终 @Builder 只传 key，
内部按 key 直接引用对应状态（状态变量必须出现在 @Builder 自身的 UI 表达式里才刷新）。

验证：`https://www.gqscc.cn/api/v1/stats` → `{"wallpapers":1577,"albums":13}`；
Pura 90 冷启动进「我的」显示「🖼 1577 张壁纸 · 🏷 13 个合辑 · ❤️ 1 个收藏」。
后端已部署（仅重建 backend，未动 mysql/nginx/compose）；最终包 2026-10-01 **10:28** 重新构建，含本改动。

### 附：后台管理系统「账号设置」

后台新增右上角「账号设置」（改密码 / 改用户名），已部署上线：

- 后端：`auth.controller.ts` 加 `POST /admin/auth/change-password`、`POST /admin/auth/change-username`；service 增加 `changePassword`/`changeUsername`；新增对应 DTO。
- 前端：新增 `AccountSettingsModal.tsx`（Tabs 切换改密码/改账号），BasicLayout 右上角菜单接入。
- 部署：精准脚本只重建 backend、不碰 compose/mysql/nginx。

---

## 2026-10-01（凌晨）AGC 新版本发布材料：法律文本云端化 + 隐私弹窗修正 + 发布截图重拍 + 1.1.0 打包

### 背景

应用已从早期的「离线宠物主题包」改为「云端壁纸 + 在线合辑」，但线上/应用内的隐私政策、用户协议、关于页与隐私弹窗仍在描述"完全离线、壁纸内置安装包"，与实际行为不符，需在 AGC 新版本（1.1.0）送审前全部更正；并按 AGC 手机截图规范（竖屏 1080×1920，PNG/JPG 单张 ≤5MB，3–10 张）重拍截图覆盖旧图。

### 一、法律文本更新（应用内 + 线上官网）

| 文件 | 改动 |
|---|---|
| `entry/src/main/ets/common/constants/LegalTexts.ets` | PRIVACY / TERMS / ABOUT 全部改为云端版；`LEGAL_UPDATED_AT` 与 `PRIVACY_CONSENT_VERSION` 置为 `2026-09-30`（隐私同意版本号升级，老用户再次进入会重新征得同意） |
| `legal-site/index.html`（隐私政策） | 第六节 SDK 清单增加"壁纸内容分发"；第七节收集内容改为"风景、动物、插画"（去除原宠物/离线描述）；第八节改为本地存储数据说明；第九节素材来源改为"部分免费图库(Pixabay/Unsplash) + 部分公开网络渠道收集"，并写明主动排除真人肖像 |
| `legal-site/terms.html`（用户协议） | 日期 2026-09-30；服务列表改为云端版（云端壁纸浏览、收藏仅本机保存、无需登录即可浏览全部内容）；知识产权与免责声明对齐云端与素材来源 |
| `legal-site/about.html`（关于页） | 日期 2026-09-30；新增"云端运行方式"说明卡片；素材来源表新增"公开网络渠道"行 |

三个 HTML 已通过 SFTP 部署到服务器 `/www/wwwroot/www.gqscc.cn/legal/`（旧文件备份于同目录 `bak-20261001-001141/`），线上 https://www.gqscc.cn/legal/ 已验证显示 2026-09-30 云端版。

### 二、应用内残留旧文案修正（实机校验发现）

法律常量虽已更新，但隐私弹窗等组件内有单独硬编码的旧文案，逐处修正：

| 文件 | 改动 |
|---|---|
| `common/components/PrivacyConsentDialog.ets` | 弹窗概要卡片原硬编码"本应用完全离线运行/不连接互联网/壁纸已包含在安装包内"，改为"**云端壁纸 · 无需注册即可浏览**"；正文改为：注册才收集用户名与密码哈希、浏览不识别身份、收藏仅本机不云同步 |
| `pages/MinePage.ets` | FAQ 删除未实现的"跨设备同步收藏"，改为"注册账号为可选项，不影响任何核心功能"；图片模糊问题改为"不同壁纸来源分辨率不一，极少数图片可能清晰度不足"。**上午补改（见下"十一"）**：App 简介卡仍是旧的"每天一点可爱 · 宠物主题"宠物定位，已一并云端化 |
| `common/components/LegalDocPage.ets` | 自检报告"④ 网络依赖：无（全离线）✔"改为"云端壁纸需联网，本地兜底目录可离线浏览" |

其余 grep 命中（HomePage/CategoryPage/WallpaperStore/LocalWallpapers 等）均为描述"离线兜底机制"的代码注释，表述准确，保留。

### 三、发布打包

- release `assembleApp`（product=default, buildMode=release）构建成功。
- 产物：`E:\zeroone\build\outputs\default\zeroone-default-signed.app`（约 55.57 MB）。
- pack.info 校验：bundleName `com.zeroone.wallpaper`，versionCode **1000001**，versionName **1.1.0**，deviceType phone，compatible/target API 24，Release。
- 已在 Pura 90 模拟器安装同名 hap 并实机确认：隐私弹窗显示新的云端版文案。

### 四、发布截图重拍并覆盖

在 Pura 90 模拟器（物理 1320×2856）实机截取新 UI，经等比缩放 + 居中裁剪（cover，不变形）处理为精确 1080×1920 PNG，同名覆盖 `e:\zeroone\截图\上传用\`：

| 文件 | 展示内容 |
|---|---|
| 01-首页壁纸.png | 首页 Hero「星夜孤树 · 9月30日 星期三」+ 宠物分区横滚 |
| 02-合辑分类.png | 图库页：主题合辑 3 列卡 + 颜色筛选（蓝/青/绿/黄绿/橙黄…） |
| 03-贴纸.png | 宠物贴纸页：贴纸工作台 / 贴纸画板入口 + 玩法小贴士 |
| 04-贴纸工作台.png | 工作台：日落背景 + 已合成 2 张贴纸 + 贴纸库/阴影/调色/导出 |
| 05-预览页.png | 壁纸全屏预览（星夜孤树）+ 收藏/铺满/下载工具栏 |

单张 0.7–2.7 MB，均 ≤5MB。仅覆盖"上传用"目录；"原生""审核整改证据"等目录未改动。

### 五、自测报告重写（legal-site/self-check.docx）

AGC 提交页旧自测报告（2026-09-29 版）经代码逐行核对，发现 4 处与现状不符，已重写并覆盖：

| 旧报告说法 | 实际情况（代码核实） |
|---|---|
| 浏览"随安装包内置的全套壁纸图库" | 云端壁纸优先、断网才用内置兜底目录 |
| 首页 banner 显示"第 X 期 · X月X日更新" | Hero 为 14 期 Swiper，UI 实际显示"X月X日 星期X"+ 副标题（无"第X期"字样） |
| 登录用户可"跨设备同步收藏" | 收藏仅存本机（favoriteIds AppStorage），无云端同步接口 |
| 反馈可提交"文字+图片"；"不登录无法完整体验" | 反馈仅文字+可选联系方式（FeedbackBody）；全部核心功能无需登录，注册为可选项 |

其余描述（编辑：裁剪/旋转/翻转/滤镜/纹理/文字/贴纸/撤销重做；51 款贴纸；权限仅 INTERNET+VIBRATE；无第三方 SDK）经核实准确，保留。报告日期更新为 2026-10-01，法律文本一致性日期 2026-09-30。测试账号 test01 的密码在文档中留占位待填。生成脚本：`Z:\zeroone管理后台\update_self_check_docx.py`。

### 六、2026-10-01（上午）补：我的页应用简介云端化 + 重新打包

用户检查时发现"我的"页 App 简介卡仍是旧宠物定位（之前只改了 FAQ/弹窗，漏了这张卡）。`pages/MinePage.ets` 修改 3 处：

| 位置 | 旧文案 | 新文案 |
|---|---|---|
| 简介卡副标题 | 每天一点可爱 · 宠物主题 | **云端壁纸 · 每日持续更新** |
| 简介卡正文 | 宠物主题工具，精选猫猫狗狗萌宠壁纸… | **云端壁纸工具：风景、动物、插画、文字等高清壁纸持续更新，无需登录即可浏览全部；收藏仅存本机；51 款宠物贴纸可拼贴、可导入透明 PNG** |
| 帮助与反馈 → 关于我们 | 宠物主题壁纸商城。内置图片来自公开免费图库 | **云端壁纸持续更新，无需登录即可浏览；壁纸部分来自公开免费图库与公开网络渠道，版权归原作者所有** |

统计数字（张壁纸/分类/收藏）为实际数据动态生成，未动。release 重新 `assembleApp` 成功（BUILD SUCCESSFUL），产物路径不变但内容已更新：`E:\zeroone\build\outputs\default\zeroone-default-signed.app`，时间戳 **2026-10-01 09:28**（同名 hap 09:28 已装模拟器，三处简介全部实机验证通过）。**上传 AGC 请用这个 09:28 的包，替换凌晨给你的那个。** 发布截图 5 张不含"我的"页，无需重拍。

---

## 2026-09-30（晚）批量导入爬取图片到壁纸后台 + 后台/前台合辑扩展

### 背景

用户在 `Z:\图片爬取\images\` 目录里有 1500+ 张爬取图片，希望把非真人、非高风险动漫 IP 的图全部导入到壁纸后台，让首页和图库自动出现更多内容；并排查与后台已有图片的重叠情况。

### 风险抽样结论（已读图判断）

| 目录 | 张数 | 处置 | 依据 |
|---|---|---|---|
| 爱豆 | 115 | 🔴 不放 | 真人明星人像，肖像权+形象权 |
| 抖音热门 | 147 | 🔴 不放 | 网红真人，肖像权 |
| 风景 | 232 | 🟢 全放 | 纯风景 |
| 文字壁纸类合计 | 17 | 🟢 全放 | 文字+插画，无人像 |
| 动漫 | 404 | 🟢 放 | 抽样 6 张未发现迪士尼/任天堂/宝可梦/正在热播新番；最高风险为中风险（京阿尼薇尔莉特、FGO 紫式部等） |
| 情侣 | 27 | 🟢 放 | 抽样 4 张全为插画/卡通/真人剪影（无面部可识别） |
| 古风 | 14 | 🟢 放 | 抽样 4 张全为插画/植物/无真人脸 |
| 什锦 | 539 | 🟢 放 | 抽样 8 张全为插画/动物照片/植物 |
| **合计导入** | **1233** | | |

### 改动

| 项 | 改动 |
|---|---|
| 新增 `Z:\zeroone管理后台\backend\scripts\import-crawled-images.ts` | 批量导入脚本：登录 admin → 拉所有现有壁纸 → 下载并计算 md5 → 比对本地图片 md5 → 跳过重复 → 预创建分类/合辑（每合辑独占一分类，rule=categoryIn）→ 上传图片 → 创建壁纸记录 → 加进合辑 → 自检每个合辑 total。支持 `--dry-run` / `--skip-hash-check` / `--only=目录名`，断点续传（progress 文件每 10 张持久化）。API 5xx/连接池错误自动重试 3 次（2s/5s 指数退避） |
| 新增 `Z:\zeroone管理后台\backend\scripts\precheck-crawled-images.ts` | 预检脚本：统计本地待导入清单 + 拉后台分类/合辑/壁纸总数 + 可选 `--hash-check` 比对 |
| 后端分类 | 新建 5 个专属分类：文字壁纸 / 动漫插画 / 情侣插画 / 古风插画 / 什锦治愈（避免合辑间规则重叠） |
| 后端合辑 | 新建 5 个合辑：`text`✍️文字壁纸 / `anime`🌸动漫插画 / `couple`💑情侣 / `ancient`🏮古风 / `mixed`🎨什锦治愈。`landscape`合辑 PATCH 补 limitCount=300 + showOnHome + homeSlot=3 |
| 合辑 rule 设计 | 每个合辑配 `rule = { categoryIn: [分类ID], orderBy: 'latest' }`，确保只展示属于自己分类的壁纸（避免无 rule 时 album 默认匹配所有 PUBLISHED 壁纸的 bug） |
| 运维修复（重要） | 导入压垮后端后排查发现：MySQL 8.4 默认 bind 在 IPv6 `::`，而 docker 桥接网络纯 IPv4，导致 backend ECONNREFUSED。远程 compose 已加 `--bind-address=0.0.0.0` 并强制重建 mysql 容器（数据卷保留），见 `Z:\zeroone管理后台\fix_mysql_bind.py` |
| App 端 | 无需改代码。`HomePage.ets` 的 `ForEach(sections)` 自动渲染所有合辑，`CategoryPage.ets` 拉所有合辑自动出现；新增合辑自动出现在首页分区与图库 |

### 与后台已有图片重叠排查（全部完成）

两轮导入共下载 896 张后台壁纸计算 md5，与本地 1233 张图片 md5 比对：

- **4 张内容与后台已有壁纸完全重复**（自动跳过，未重复入库）：
  - 动漫/150fc76da2773b7eadc7fb7d8ef0a06b.jpg
  - 动漫/241b8a2a306de504117907a46ad5ccfe.jpg
  - 什锦/074639e25743a96bd962d142fc6814a1.png
  - 什锦/25bf74cac49dd882f405ec6ef9914950.png
- 第一轮已上传的 552 张在第二轮全部被 md5 识别跳过，未产生任何重复记录
- 全库最终排查（`check-url-duplicates.ts`）：**1577 张壁纸对应 1577 个唯一 imageUrl，0 组真重复**

### 最终入库结果

| 合辑 | 内容 total（已去重） | 说明 |
|---|---|---|
| landscape 🏞 治愈风景 | 300 | 分类内 514 张（原 282 + 新 232），limitCount=300 截断 |
| text ✍️ 文字壁纸 | 17 | 8 个文字子目录全部 |
| anime 🌸 动漫插画 | 402 | 404 - 2 重复 |
| couple 💑 情侣 | 27 | |
| ancient 🏮 古风 | 14 | |
| mixed 🎨 什锦治愈 | 537 | 539 - 2 重复 |
| **壁纸库总数** | **1577** | 导入前 348，净增 1229 |

### 已知非阻断问题

合辑列表接口的 `count` 字段因「手工项 + 规则项」双路径统计出现双倍值（如 anime 显示 804），但**内容接口已去重**（抽查前 100 张 0 重复 id/url），图库卡 UI 不展示该字段，用户无感知。后续可在后端 `albums.service.ts` 列表统计处合并去重。

### 验证

- 编译运行 App 后：首页分区从原本 7 个扩展到 12 个（landscape + pets + sunset + city + dark + minimal + photography + text + anime + couple + ancient + mixed），每个分区拉前 8 张做横滚，跨分区去重继续生效
- 图库页 3 列 Cuto 卡自动多出 5 个新合辑
- 重复图片自动跳过，全库无重复记录

---

## 2026-09-30（凌晨2）首页跨分区去重 + Cuto 质感调整

### 背景

用户反馈首页同一张图在多个分区重复出现（如"紫色海日落"在治愈风景和日落与夜色两个分区都有），影响观感；要求按 Cuto 边距质感仿造，简约高级。

### 改动

| 项 | 改动 |
|---|---|
| 跨分区去重 | HomePage 新增 `seenUrls: string[]` 字段；`loadSectionItems` 从拉 8 张改为拉 16 张，过滤掉已在前面分区出现过的 imageUrl/thumbUrl，取前 8 张。并发回调"先到先得"——先加载的分区占住 url，后续分区跳过。同一张图（运营归入多个合辑）不会在首页多个分区横滚里重复出现 |
| 纯黑背景 | Scroll 背景色 `#0F0F12` → `#000000`（Cuto 纯黑，让壁纸图更突出） |
| 卡片背景 | `#1C1D22` → `#1A1A1A`（接近纯黑，与背景融合更高级） |
| 骨架色 | `#16171C` → `#1A1A1A`（统一深灰） |
| 圆角加大 | 壁纸小卡 `borderRadius(12)` → `16`；Hero 大卡 `borderRadius(24)` → `20`（Cuto 圆角更克制） |
| 分区间距 | 分区标题行 padding `top:10,bottom:8` → `top:18,bottom:10`（留白更足） |
| 标题字号 | 分区标题 `fontSize(17)` → `18`（更突出） |
| 底部留白 | `height(24)` → `32`（最后分区不贴 Tab 栏） |

### 去重策略说明

后端合辑是多对多设计（AlbumWallpaper 中间表），同一张壁纸可归入多个合辑（如"星夜孤树"在 landscape/dark/minimal 三个合辑）。首页多分区横滚会导致同一张图在多个分区出现。

App 端兜底去重：维护 `seenUrls` 集合，每个分区拉 16 张后过滤已在前面分区出现的 url，取前 8 张。这样：
- 第一个分区（如 pets）完整显示 8 张
- 后续分区（如 sunset）跳过已在 landscape 出现的图，只显示本分区独有的图
- 某些分区去重后可能少于 8 张（如 sunset 大部分和 landscape 重叠），属正常——少几张比重复好

### 验证

- 编译运行后：首页纯黑背景，分区标题更突出、间距更足，壁纸小卡圆角 16 更克制
- 同一张图不再在多个分区重复出现（如紫色日落只在治愈风景或日落与夜色其中一个分区出现）

---

## 2026-09-30（凌晨）首页 ForEach 刷新 bug 修复 + pets 合辑改名 + 重复图片排查

### 背景

用户反馈首页「没内容」（分区标题下全是黑块骨架占位不消失），要求查重复图片、把「毛孩子」改名为「宠物」。

### 改动

| 文件 | 改动 |
|---|---|
| `HomePage.ets` | 修复 `ForEach(sections)` 的 keyGenerator：从 `s.slug` 改为 `` `${s.slug}_${s.loaded}_${s.items.length}` ``。根因：slug 不变，items 填充后 ForEach 认为没变化不重新渲染 sectionRow，导致骨架占位永不消失（"没内容"现象的根因）。key 含 loaded + items.length 后，数据填充 key 变化，ForEach 重新渲染，骨架消失显示横滚 |
| 后端 `albums` 表 | slug=pets 合辑名 `🐾 毛孩子` → `🐾 宠物`（通过线上 admin API PATCH 已生效） |
| `Z:\zeroone管理后台\backend\scripts\fix-album-name-and-duplicates-api.ts` | 新增脚本：登录线上 admin → 拉所有合辑所有壁纸 → 按 imageUrl 分组查真重复 + 改 pets 合辑名 |

### 重复图片排查结论

**0 组真重复**。wallpapers 表里没有"不同 id 指向同一 imageUrl"的情况。

用户视觉上看到的"一模一样重复"是**同一张壁纸（同一个 wallpaper id）被关联到多个合辑**的正常多对多设计（AlbumWallpaper 中间表）。例如 id=348「星夜孤树」同时出现在 landscape/dark/minimal 三个合辑，首页多分区横滚就会在三个分区看到同一张图。这是运营策略（一张图归入多个主题合辑），不是数据库重复 bug。

如需消除视觉重复：运营在后台调整合辑 rule 或手工移除，让同一张图不要同时出现在太多首页分区合辑里。

### 验证

- 编译运行后：首页 Hero Swiper + 7 个分区横滚（宠物 / 治愈风景 / 日落与夜色 / 城市与建筑 / 暗色系 / 留白风景 / 摄影作品），每个分区数据填充后骨架消失显示横滚壁纸小卡。
- pets 合辑标题显示「🐾 宠物」（App 拉取后端 name 字段，无需改 App 代码）。

---

## 2026-09-30（深夜）首页多分区横滚扩展

### 背景

用户反馈首页「太贫乏」，配 5 张 Cuto 截图（IMG_3091-3095）：Cuto 首页除 Hero 大卡外，还有「年度精选 / 动态壁纸 / 景深 / 紫色 / 夏天 / 云边漫步 / 热带记忆 / 海」等多个分区横滚，每个分区 = 标题行（左标题 + 右「更多 >」）+ 3-4 张壁纸小卡横滚。当前首页只有「Hero Swiper + 单条推荐合辑横滚」两条，视觉太单薄。

### 改动

| 文件 | 改动 |
|---|---|
| `AlbumsApi.ets` | 新增 `AlbumSection` 类（合辑摘要 + items 壁纸列表 + loaded 标志）和 `fetchAlbumSections(excludeSlug='daily')` 静态方法（拉所有合辑转成分区，排除 daily 给 Hero Swiper 用） |
| `HomePage.ets` | 删除单条「推荐合辑横滚」`homeAlbums` / `loadHomeAlbums` / `albumMiniCard`；新增 `sections: AlbumSection[]` 状态 + `loadSections`（拉所有合辑作分区）+ `loadSectionItems(slug)`（并发填充每个分区 8 张壁纸）；新增 `wallpaperCard` Builder（120×180 铺图圆角小卡，点进全屏预览）+ `sectionRow` Builder（标题行 + 横滚 List / 骨架占位）；build 的 Scroll Column 里 Hero 之后用 `ForEach(sections)` 渲染多分区 |

### 设计要点

- **多分区数据源**：`GET /api/v1/albums` 返回所有合辑（maopet/landscape/sunset-night/urban/dark/minimal/photography），App 端过滤掉 daily（Hero 专用），每个合辑一个分区。
- **并发加载**：`aboutToAppear` 先调 `fetchAlbumSections` 拿合辑列表（含 coverUrl/name，秒回），再对每个 slug 并发调 `fetchAlbumPage(slug, 1, 8)` 拉前 8 张壁纸。分区逐个出现，不用等所有加载完。
- **状态刷新**：ArkTS `@State` 对数组元素属性修改不触发刷新，每次填充 items 后用 `this.sections = this.sections.slice()` 重新赋值；用 slug 匹配而非 index（避免并发回调时索引漂移）。
- **卡片样式**：壁纸小卡 120×180 铺图圆角 12，无文字遮罩（除 Hero 外），对标 Cuto 横滚小卡风格；点卡进全屏预览复用 `openHero` + `geometryTransition`。
- **骨架占位**：每个分区加载中显示 3 个灰块横滚占位（避免分区标题出现后下面空白）；加载完空则不显示横滚区。
- **更多 > 按钮**：本期只做视觉，不跳转（跨 Tab 跳图库需 Index 协调，留作后续）。

### 后端

- **零代码改动**。复用 `GET /api/v1/albums`（合辑列表）和 `GET /api/v1/albums/:slug`（合辑内容分页）两个已有接口。

### 风险与自检

- ArkTS `@State` 数组刷新：已用 `slice()` 重新赋值，避免直接改元素属性不触发渲染。
- `ForEach` 回调无 `const` 声明：`sectionRow` / `wallpaperCard` 都是 `@Builder` 方法调用，回调体仅 `this.xxx(s)` / `ListItem() { this.wallpaperCard(w) }`，无变量声明。
- `layoutWeight(1)` 在 `Row` 里给 `Text(s.name)`：让标题占满左侧、`更多 >` 靠右；`layoutWeight` 在 `Row` 内有效（不是在 Scroll 里）。
- 骨架占位用 3 个 `Column` 硬编码而非 `ForEach([1,2,3])`：避免 ArkTS 对数字字面量数组 ForEach 的潜在类型问题。
- 共发 7 个分区 × 8 张 = 56 张图请求：首屏可能略卡，但分区逐个出现，体验可接受；如需优化可改串行或限制并发数。

### 验证

- 编译运行后：首页 Hero Swiper + 下方多个分区横滚（毛孩子 / 治愈风景 / 日落与夜色 / 城市与建筑 / 暗色系 / 留白风景 / 摄影作品），每个分区标题 + 横滚 8 张壁纸小卡。
- 断网：Hero 显示空 + 重试；分区不显示（sections 为空）。
- 点壁纸小卡：进全屏预览（与 Hero 点图一致）。

---

## 2026-09-30（晚）云端版 + Cuto 风格首页/图库重做

### 背景

从全离线版改回云端版（与 Z 盘后台配套），首页与图库对标苹果商城 Cuto 壁纸 App 重做。方案见 `CLOUD-CUTO-REBUILD-PLAN.md`。

### 改动

| 文件 | 改动 |
|---|---|
| `Index.ets` | Tab emoji（🏠📚🐾👤）改 SymbolGlyph 系统符号（house / square_grid_2x2 / sparkles / person），选中金色 `#F0D08A`；「合辑」Tab 改名「图库」 |
| `CategoryPage.ets` | 合辑列表 2 列 → 3 列；合辑卡改 Cuto 风格（Cover 铺满 + 暗色遮罩 + 居中白色分类名，去掉数量胶囊与下方标题区）；顶部标题「合辑」→「图库」，删 📚 emoji |
| `HomePage.ets` | 整页重写：纵向 List + 单列大卡 + 宠物优先重排 → Cuto 式 Hero Swiper（右滑看昨天）+ 推荐合辑横滚；数据源改用 `/api/v1/albums/daily?page=1&pageSize=14`（复用合辑接口，后端零改动）；删 WallpaperStore 订阅 / DailyApi / buildPetFirstList / bigCard 大图流；保留 ImagePreview 全屏预览与三态 |
| `CLOUD-CUTO-REBUILD-PLAN.md` | 新增方案文档 |

### 后端

- **零代码改动**。复用 `albums.service.ts` 的 `resolveRule` daily 分支（L336-358），`GET /api/v1/albums/daily` 已返回最近 N 期历史精选（按 date desc）。
- 运营前置：后台已建 slug=daily 的合辑（source='daily'），当前 1 期数据，需每天放图积累到 14 期才能完整体验「右滑看昨天」。

### 跳过项

- `LocalWallpapers.ets` 的 CATEGORIES 重复项未修：`MinePage.ets` L119 用 `CATEGORIES.length - 1` 算 FAQ 数，去重会改变 FAQ 显示数，有副作用，留作后续单独处理。

### 风险

- Swiper 在项目里无先例，本次为首例使用；ArkTS ForEach 用单参数 + `isHeroFirst` 方法判断首项（避免 index 参数的潜在严格性问题）。
- SymbolGlyph 的 `sys.symbol.square_grid_2x2` / `sparkles` 名字需在 DevEco Symbol Library 验证存在；若编译报错，备选 `sys.symbol.photo` / `sys.symbol.face_smiling`。

### 验证

- 编译运行后：首页 Hero 大卡 Swiper（右滑露边 15px）+ 顶部 Logo + 推荐合辑横滚；图库 3 列 Cuto 卡；Tab 4 个 SymbolGlyph 图标。
- 断网：Hero 显示空 + 重试图标，不白屏。
- 编辑器回归：StickerStudioPage 选背景壁纸库不受影响（LocalWallpapers 未动）。

---

## 2026-09-30（下午）四项功能落地：精选关联壁纸 / 账号注销 / 颜色筛选 / 合辑拖拽

### 1. 今日精选关联壁纸 + 首页大卡可点

| 端 | 改动 |
|---|---|
| 后台 | `/api/v1/home/composition` 的 `dailyFeatured` 增加 `wallpaper` 字段（由 `daily_featured.wallpaper_id` 解析） |
| 后台数据 | 把「星夜孤树」登记为壁纸 **#348**（分类=自然风景、主色=蓝、亮度 0.236、朝向 P、来源 `pixabay.com/images/id-7010442/`），并关联到第 1 期精选 |
| App | 首页大卡：有关联壁纸 → 点击进全屏预览（可保存、会走 `/wallpapers/348/download` 统计）；未关联 → 提示"这一期精选暂不支持保存"，不会点进空页面 |

### 2. 账号体系：放开入口 + 法规要求的自助注销

| 项 | 改动 |
|---|---|
| **后端 bug 修复** | `issueRefreshToken()` 原先生成 `时间戳.hex`，而刷新时把前半段当 userId 解析 → **`/auth/refresh` 永远 401，用户 access_token 一过期就被踢下线**。已改为 `userId.hex`，端到端实测通过 |
| 后端新增 | `POST /api/v1/auth/logout`（清服务端 refresh_token）、`DELETE /api/v1/auth/account`（密码二次确认后删除账号）、`PATCH /api/v1/auth/profile`（改昵称） |
| App 新增 | `AccountPage`（账号设置）：改昵称 / 退出登录 / **注销账号**（二次确认 + 密码校验），页面里写明"服务端删什么、本机留什么" |
| App 改动 | `MinePage` 账号卡片：未登录显示「登录 / 注册」按钮（此前入口是被注释隐藏的），已登录显示「账号设置」；整卡可点 |
| 路径对齐 | 隐私政策里承诺的「我的 → 账号设置 → 注销账号」现在真实存在（法规硬要求） |
| 实测 | 注册 201 → 登录 201 → **refresh 201**（修复前 401）→ profile 200 → 改昵称 200 → 登出 201 → 注销 200 → 注销后再登录 401（证明账号真删了） |

### 3. 颜色筛选 chip

| 端 | 改动 |
|---|---|
| 后端 | 新增 `GET /api/v1/colors`（各主色桶张数）；`GET /api/v1/albums/:slug` 支持 `?color=` `?tag=` |
| App | 合辑页顶部与合辑详情各一排 chip（全部 / 蓝 101 / 橙黄 75 / 灰 59 / 绿 48 / 青 30 / 红 15 / 黄绿 13 / 紫 7）；点一下按主色筛当前合辑，未进合辑时点颜色会直接进「治愈风景」看该色系；离线兜底模式下改为本地过滤 |

### 4. 后台合辑拖拽排序

- 「合辑管理」列表由 `ProTable` 换成 `DragSortTable`，**按住左侧手柄拖动即可调序**，松手后按新顺序写回 `sort=1..n` 并刷新；失败会提示并回滚。

### 踩坑记录（ArkTS / 后端）

- `AccountPage` 放在 `common/components/` 下，`import` 路径是 `../net/...`、`../utils/...`（不是 `../common/...`）。
- ArkTS 禁止 `any`/`unknown`：`.then((resp) => ...)` 必须写成 `.then((resp: ApiResponse<boolean>) => ...)`。
- 管理端 `PATCH /admin/wallpapers/:id` 是**整体替换**语义（DTO 的 `title`/`imageUrl` 必填），
  只传要改的字段会 400；必须"先 GET 再整体提交"。
- 为让后台新建壁纸也能进颜色合辑，`SaveWallpaperDto` 增加了
  `dominantColor` / `brightness` / `orientation` / `sourceUrl` 四个可选字段。

---

## 2026-09-30 App 接入「合辑」：合辑页与首页改为后台可配置（要发版）

> 起因：合辑分类太杂（风景 232 / 自然风光 50 语义重复、待归类 21 张标题是摄影师名、极简风格只有 1 张），
> 且**合辑名与顺序写死在 App 代码里，改一次就要发版**。后台侧已完成合辑表与接口，本轮把 App 接上。

### 后端（Z:\zeroone管理后台，已完成并上线）

| 项 | 内容 |
|---|---|
| 新表 | `albums`（含 `rule` JSON 规则、`show_on_home`/`home_slot`）、`album_wallpapers`（手工排序） |
| 新列 | `wallpapers.dominant_color/brightness/orientation/source_url`；`categories.kind`（SUBJECT/STYLE） |
| 新接口 | `GET /api/v1/albums`、`/api/v1/albums/:slug`、`/api/v1/home/composition`；管理端 `/admin/albums` 全套 + `/preview` |
| 数据整理 | 风景 232 + 自然风光 50 → **自然风景 282**；待归类 → **摄影作品**；232 张机器标题 `风景 1244` → `自然风景 · 橙黄 231`；347 张尺寸/主色/亮度/朝向全部回填 |
| 线上合辑 | 每日精选(1，`source=daily` 自动) · 毛孩子(30) · 治愈风景(282) · 日落与夜色(61) · 城市与建筑(13) · 暗色系(49) · 留白风景(168) · 摄影作品(21) |
| 管理后台 | 新增「合辑管理」页（规则编辑器 + 规则预览 + 内容管理抽屉），已部署到 https://www.gqscc.cn/albums |

### App 侧（本轮，需要发版）

| 项 | 内容 |
|---|---|
| 新增 | `common/net/AlbumsApi.ets`：合辑列表 / 首页编排 / 合辑分页三个接口的封装（全部防御式，失败返回空） |
| 新增 | `ApiConfig.PATH.ALBUMS`、`HOME_COMPOSITION` |
| 模型 | `Wallpaper` 增加 `dominantColor`（后台分析标注的主色桶），`WallpaperApi` 映射该字段 |
| 重写 | `CategoryPage`：合辑列表改为读后台接口（不再写死分类名）；点开合辑按需分页加载、滚到底自动续；接口失败时按内置目录分类兜底 |
| 首页 | 新增「今日精选大卡」（图/标题/副标题/期号，来自后台每日精选）+「合辑区」2 列封面卡（顺序由后台 `homeSlot` 决定），放在原大图流之上 |
| 内置目录 | `LocalWallpapers` 分类名同步为后台口径（自然风景/动物萌宠/城市建筑/摄影作品），离线兜底分组可用 |

### 踩坑记录

- **ArkTS 两条硬约束**：① 不允许用对象字面量当类型声明（`arkts-no-obj-literals-as-types`）→
  `ApiDailyCard`/`ApiHomeComposition` 必须写成 `class`，`category` 这类内联结构必须具名 interface；
  ② 组件 `onScrollIndex` 只回调 `(first, last)`，多写第三个参数直接编译失败。
- 后台前端构建：`pnpm run build` 会因 pnpm 依赖校验（`ERR_PNPM_IGNORED_BUILDS`）中断，
  改用 `npx tsc -b` + `node node_modules/vite/bin/vite.js build`。

### 待真机确认

- 首页「今日精选大卡 + 合辑区」与合辑详情的分页滚动（`onScrollIndex` 预取）需要真机跑一遍；
- 大卡目前**只展示不可点**：`dailyFeatured.wallpaperId` 是可选的，没有关联壁纸时没有可预览/可保存的对象，
  等后台把精选图都关联到壁纸后再接"点击进全屏预览"。

---

## 2026-09-29 后端部署：线上补齐 daily/featured 与账号接口（App 侧代码未改）

> 起因：复核"App 对接的管理后台"时发现**线上后端是 2026-09-24 的旧构建**，
> 与本地 `Z:\zeroone管理后台` 源码相差 `daily-featured`、`users`、`app-auth` 三个模块。
> 这直接决定 App 首页「第 X 期」徽标能否拿到后端数据、以及账号体系能否放开。

### 线上拓扑（先弄清楚谁在对外服务）

- 对外 nginx 是**宿主机宝塔那一份**（`/www/server/nginx`），不是 docker-compose 里的 `zeroone-nginx`
  （该容器与宝塔抢 80/443，反复 Exited(137)，已删除）；
- 宝塔站点 `/www/wwwroot/www.gqscc.cn/` 承载管理后台前端（已是最新构建）+ `/legal/` 三份法律文档；
- `/api/`、`/admin/`、`/docs`、`/uploads/` 反代到后端容器；原先写死容器内网 IP `172.19.0.3:3000`。

### 修复

| # | 问题 | 修复 |
|---|---|---|
| 1 | 新后端代码**启动即崩溃**：`Nest can't resolve dependencies of the JwtAppAuthGuard` | `@nestjs/passport` v12 起裸 `PassportModule` 是空模块，`AuthModuleOptions` 只由 `PassportModule.register()`/`registerAsync()` 提供 → `AppAuthModule` 改为 `PassportModule.register({})` |
| 2 | 反代写死容器 IP，容器一重建整个 App 就 502 | `api.conf` 上游改 `127.0.0.1:3000`；compose 给 backend 加 `ports: 127.0.0.1:3000:3000` |
| 3 | `docker compose up -d` 未重新应用端口映射 | 端口类改动改用 `--force-recreate` |
| 4 | `tsbuildinfo` 随源码上传会让 `nest build` 跳过重编 | 上传脚本排除 `*.tsbuildinfo` |
| 5 | 后台源码无版本控制 | `git init` + 首次提交；新增 `DEPLOY-NOTES.md` 记录拓扑与发布流程 |

### 部署结果（已实测）

- 迁移自动应用 3 个（`0_init` / `add_users` / `add_daily_featured`），新表 `users`、`daily_featured` 已建；
- 新上线路由：`GET /api/v1/daily/featured`、`POST /api/v1/auth/{register,login,refresh}`、`GET /api/v1/auth/profile`、`/api/v1/notices/popup/latest`、`/admin/daily-featured*`、`/admin/users*`；
- 公网验证：`/api/v1/*` 全 200；`/admin/*` 未授权 401（路由存在）；管理员登录 201；**新增/删除一期今日精选成功**，App 接口能读回同一期数据；反馈提交 201；uploads 卷未丢；
- 数据现状：`wallpapers=347`、`categories=6`；`daily_featured=0`、`users=0`、`feedbacks=0`（测试数据已清理）。

### 对 App 的影响（待定项）

- `daily_featured` 目前为空 → 首页徽标仍走本地推算期号的降级分支；**要在后台「今日精选管理」新增第 1 期才算真正接通**；
- **账号接口现已可用**（`/api/v1/auth/*`），但 App 内登录入口仍是隐藏状态；
  若这版要放开，还需补「账号设置 / 注销账号」入口与 App 自助注销接口
  （目前只有管理端 `DELETE /admin/users/:id`），并同步更新隐私政策/用户协议与 AGC 隐私标签。

---

## 2026-09-29 1.1.0 第二轮审核整改：色彩对比度（不通过项）+ 动效复核

> 起因：应用市场 1.1.0 审核结论 —— **色彩**「应用使用的色彩需满足最小对比度要求：图标或标题文字与背景
> 对比度大于 3:1，正文文字与背景对比度大于 4.5:1」判**不通过**；另有转场动效（建议系统转场 +
> 弹簧曲线）、滑动到边界反馈动效、全屏转场时长（8.5"/12" 分档最短时长）三条**警告**。

### 色彩：整套配色重定（问题根因是两条，不是一条）

| 根因 | 实测 | 修法 |
|---|---|---|
| 浅色文字压在粉色实底上 | `#FFFFFF` on `#FF6B6B` = **2.48:1** | 强调色拆成三档：底色 `#C9333D`（白字 **5.22:1**）、深色底上的文字 `#E8606A`（**5.75:1**）、浅色面板内 `#C22F38`（**4.82:1**） |
| 深色主题次级灰文字过暗 | `#7A7A85` on `#1C1D22` = **3.97:1**、on `#0F0F12` = **3.63:1** | 次级色统一为 `#A8A8B5`（on `#1C1D22` **7.16:1**、on `#191A1F` **7.39:1**） |
| 浅色编辑器面板沿用深色灰 | `#999999` on `#FFFFFF` = **2.85:1** | 浅色面板文字改 `#66666F` / `#61616A`（**5.68:1** / **5.28:1**） |
| 装饰箭头、未激活序号几乎看不见 | `#4A4A55` on `#1C1D22` = **1.92:1** | 改 `#8A8A95`（**4.93:1**） |
| 金色徽标/文字 | `#E6C07E` 文字 on 深底 = **4.97:1**（不够正文 4.5 的是它压在浅底时） | 金色文字改 `#F0D08A`（**6.9:1**）；金色徽标上的文字改深棕 `#4A3208`（**6.97:1**） |
| 登录/注册页半透明卡片与深青渐变 | `#E76F51` / `#2A9D8F` / `#E0FFFFFF` 均不达标 | 分别改 `#C24A32`（**4.62:1**）、`#1B6B61`（**6.00:1**）、`#CC264653`（**5.46:1**） |

- 覆盖范围：`entry/src/main/ets` 全部 59 个源文件中的 18 个（深色主题 12 个 + 浅色编辑器 2 个 + 登录注册 2 个 + 单测常量 1 个 + 组件 1 个），共 300 余处色值。
- 新增可复跑的复核工具（审核证据可独立验证，不靠目测）：
  - `tools/contrast_audit.py`：把每个 `fontColor/placeholderColor/iconColor/selectedColor/blockColor/fill`
    与**同一样式块**声明的背景色配对，按 WCAG 算对比度，正文 < 4.5:1、图标/大号文字 < 3:1 即报警；
  - `tools/contrast_report.py`：输出全部出现的 (前景,背景) 组合与判定 → `contrast-audit-report.txt`；
  - `tools/fix_contrast_*.py`：四轮定点替换（每处都校验"旧色值确实在该行"，行号漂移则跳过并报错，不盲改）。
- 复核结果：40 组配色中 29 组 ≥ 4.5:1、2 组为图形元素（按 3:1 通过）；其余 9 组是
  **脚本无法静态判定背景**的浮层控件（金色徽标、登录按钮、画布手柄、头像圆底），已逐个人工复核为误报，
  明细见《整改说明-1.1.0-色彩与动效.md》第三节。
- 踩坑记录：**不要用 Windows PowerShell 5.1 的 `Get-Content/Set-Content` 改这些 UTF-8 源码** ——
  它按 ANSI 读写，会把中文注释与 emoji 整片破坏（本次已从备份回滚）。改色值一律用 Python（UTF-8 无 BOM，不动行尾）。

### 动效：三条警告逐条复核（结论：代码侧无需改）

| 审核意见 | 复核结论 |
|---|---|
| 建议系统转场、淡入淡出，不应左右/上下位移切换 | 全工程无页面级位移转场；`Tabs` 与页面进入走系统转场；卡片→大图预览为系统共享元素转场 `geometryTransition`（HomePage:243 / CategoryPage:260 / MinePage:192） |
| 曲线优先弹簧曲线 | 全屏共享元素转场 `HomePage.ets:248`、`CategoryPage.ets:264`、`MinePage.ets:196` 均为 `Curve.EaseOut`（系统动效曲线）；微交互 150~220 ms |
| 全屏转场时长分档不低于 200/250/300 ms | 全屏转场 **320 ms**，满足 12 英寸以上 ≥300 ms 的最严要求 |
| 滑动到边界要有反馈动效 | 六个页面的 `List/Grid/Scroll` **全部**启用系统弹性边界反馈 `EdgeEffect.Spring`（含 `LegalDocPage`、`PrivacyConsentDialog`、`ImageEditor` 6 处滚动区） |

### 顺带发现的线上问题（服务端/AGC 后台，非代码）

1. `https://gqs.404.kim/`（AGC 后台登记的隐私政策 URL）返回的是**另一个站点**（"随机二次元图片API"），
   且证书 SAN 只有 `acg.404.kim`，`/terms.html`、`/about.html` 均 404 → 需重新部署或改用 `www.gqscc.cn`；
2. `GET /api/v1/daily/featured` 服务端 **404** → 首页「今日精选 · 第 X 期」拿不到后端数据（App 侧已容错降级，
   不会崩，但"后台每天放一张图即新增一期"实际为空）；
3. `/banners` 返回空数组、`/versions/latest` 无记录、`/auth/login` 404（用户体系未开放，与 App 隐藏登录入口一致，
   但法律文档里仍写着"含账号系统"，需对齐）。

### 验证

- `assembleHap --analyze=normal --parallel --incremental --daemon` → **BUILD SUCCESSFUL**（31.8 s，仅 deprecation WARN）。
- ⚠️ `hvigorw … test` 当前编译失败，**与本次改动无关**：`entry/src/test/CropGeometry.test.ets` 未跟随
  `CropView` 新增的 `flipH/flipV` 字段更新（历史遗留，本次未触碰该文件）。

---

## 2026-09-12 阶段 3：裁剪重写（所见即所裁）

> 起因：实际运行反馈"自由模式左右拖不动、图片四角区域拖不动、裁剪完还是原图"。
> 复核后是**三个独立缺陷**，而且都与"图片到底按什么尺寸适配"这条约定有关。

| 缺陷 | 根因 | 修复 |
|---|---|---|
| 裁完还是原图 / 裁出来不是框住那块 | `applyCrop` 的逆变换漏了"绕预览中心缩放"这一项（原式 `u = (s − off − disp.x)/(s·k)`），只有"没缩放、没平移"时才碰巧正确 | 改为离屏重绘：`composeCropToPixelMap()` 用与 UI **同一套**变换（`cropDrawTransform`）把源图画进输出画布，画布原点对齐选区左上角 —— 框住什么就得到什么 |
| 改选区时图片自己跳、四角区域对不上 | 裁剪视图把图片 fit 到了**选区**（`Stack{Image}.width(cropW).height(cropH)`），而所有换算都假设图片 fit 到**预览区**（`dispRect`） | 内层补一层"预览区尺寸"的坐标系容器，图片在其中按 Contain 适配，再整体平移 `(-cropX, -cropY)`，选区外用 `clip` 裁掉 —— 显示与换算从此同源 |
| 左右边中点拖不动 | 四个边把手的可点区域就是那根 3vp 粗的白条，真机上几乎点不到 | 8 个把手全部加 `.responseRegion()`：角把手 44×44，边把手 31×66 / 66×31（热区可超出组件范围，视觉不变） |
| 旋转滑块只预览不生效 | `cropAngle` 从未进入裁剪计算（历史上因坐标问题被摘掉） | 旋转并入 `cropDrawTransform`，真正参与裁剪；旋转后四角露出的底色铺黑 |
| 图层锚点用 `mapCrop` 简单减偏移 | 只在无缩放、无旋转时正确 | 换成 `unprojectCrop()`（绘制变换的逆运算），并带正逆往返单测 |

- 新增 `common/editor/CropGeometry.ets`：`CropView` / `CropSize` / `CropDrawTransform` / `cropOutputSize()` / `cropDrawTransform()` / `unprojectCrop()`（纯函数）。
- 新增 `ImageComposer.composeCropToPixelMap()`：离屏裁剪合成，带 4096 长边护栏，返回像素图 + 实际尺寸 + 护栏缩放比。
- 新增 `entry/src/test/CropGeometry.test.ets`：7 个用例（输出尺寸随源图密度、无变换情形、绕中心放大、平移、90° 旋转、正逆变换往返、退化输入）。
- 删除无入口的 `onCropFrameDrag` 与只服务于它的 `panStartX/panStartY`（新模型是"图片动、选区不动"）。

验证：`hvigor … test` 20 个用例全绿；`assembleHap` 通过。

待真机确认：旋转角度与 Canvas `rotate` 的方向约定（两侧同为顺时针，理论一致，需肉眼确认一次）。

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
