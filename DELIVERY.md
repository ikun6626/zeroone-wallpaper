# ZeroOne 壁纸商城 App —— 交付说明

> HarmonyOS NEXT（ArkTS + ArkUI）+ 华为 AGC 云服务（云数据库）
> 最后同步：2026-09-12

## 一、代码结构

```
entry/src/main/ets/
├── model/
│   └── Wallpaper.ets                    # 壁纸实体（与云表字段一一对应，10 字段）
├── common/
│   ├── components/
│   │   ├── ImagePreview.ets             # 全屏预览（缩放/滑动关闭/锁屏桌面模拟/保存/设为锁屏桌面/进编辑器）
│   │   ├── ImageEditor.ets              # 图片编辑器（旋转/裁剪/滤镜/纹理/艺术字/贴纸/导出）
│   │   ├── SetWallpaperGuide.ets        # 「设为壁纸」闭环：步骤文案 + 弹窗 + 引导卡片 + 复制步骤
│   │   └── LegalDocPage.ets             # 隐私政策 / 用户协议 / 关于与版权 / 清除缓存
│   ├── constants/
│   │   └── DefaultWallpapers.ets        # 分类、预置标签、内置 22 张壁纸与本地图映射
│   ├── editor/
│   │   ├── ImageComposer.ets            # 离屏合成导出（**所见即所得**的唯一出处）
│   │   ├── FilterTask.ets               # 20 滤镜 + 5 纹理（@Concurrent，跑在 TaskPool）
│   │   ├── CropGeometry.ets             # 裁剪框几何（8 把手 + 6 比例）
│   │   ├── LayerGeometry.ets            # 文字/贴纸锚点随裁剪旋转翻转的映射
│   │   ├── EditorModels.ets             # TextItem / StickerItem（含 angle）/ DispRect
│   │   └── EditorConstants.ets          # 滤镜名、纹理名、文案库、颜色表
│   ├── store/
│   │   └── WallpaperStore.ets           # 唯一数据源：缓存优先 + 分页 + 状态键 + retry
│   └── utils/
│       ├── CloudDBUtil.ets              # 云数据库查询/分页/按分类/播种
│       ├── PreferenceUtil.ets           # 收藏持久化 + favoriteIds 广播 + 字符串 KV
│       ├── PixelScope.ets               # PixelMap 生命周期作用域（防 OOM）
│       ├── EditGuard.ets                # 返回键拦截栈 + 放弃编辑确认
│       └── AppInfo.ets                  # 真实版本号
├── pages/
│   ├── Index.ets                        # 4 个 Tab（🏠首页 📚合辑 🐾贴纸 👤我的）+ 返回键分发
│   ├── HomePage.ets                     # 大图卡片流：骨架屏/错误重试/离线提示/上拉分页
│   ├── CategoryPage.ets                 # 合辑墙 + 等比网格详情
│   ├── StickerPage.ets                  # 贴纸枢纽（工作台 / 画板）
│   ├── StickerStudioPage.ets            # 贴纸工作台（选背景 → 合成 → 存图/锁屏图/桌面图）
│   ├── StickerBoardPage.ets             # 多贴纸画板
│   └── MinePage.ets                     # 商城介绍 + 收藏 + 帮助反馈 + 法律与关于
```

> 历史上存在 7 个无调用方的文件（`StickerCanvasComponent`、`StickerProcessor`、`WallpaperExporter`、
> `PhotoEditorPage` 与 `common/photoeditor/` 三件套）以及记录它们的 `DEPRECATED.md`，
> 已于 2026-09-12 全部删除；工程已纳入 git，回滚靠版本历史而不是留档文件。

## 二、华为 AGC 控制台配置（一次性，约 10~15 分钟）

> 控制台：<https://developer.huawei.com/consumer/cn/service/josp/agc/index.html>

### 第 1 步：创建项目与应用

1. 华为账号登录 → **我的项目** → **创建项目**（如 `ZeroOne壁纸`）；
2. 项目内 **添加应用** → 平台选 **HarmonyOS** → 包名填 **`com.zeroone.wallpaper`**
   （⚠️ 必须与 `AppScope/app.json5` 的 `bundleName` 完全一致）。

### 第 2 步：下载 agconnect-services.json

项目设置 → 常规 → 下载配置文件 → 放到：
```
E:\zeroone\entry\src\main\resources\rawfile\agconnect-services.json
```
（位置不能错，否则报 `agconnect sdk not initialized`）

### 第 3 步：开通云数据库

> 本项目用 SDK **自带**的 Cloud Foundation Kit（`@kit.CloudFoundationKit`），**无需安装任何三方 ohpm 包**。

1. 云开发 → **云数据库** → 创建存储区域(zone)，名称 **`zeroone`**
   （⚠️ 与 `CloudDBUtil.ets` 的 `ZONE_NAME` 一致）；
2. 区域内容创建对象类型 **`wallpapers`**
   （⚠️ 与 `Wallpaper.ets` 的 `naturalbase_ClassName()` 一致）；
3. 添加 **10 个字段**：

   | 字段名 | 类型 | 主键 | 说明 |
   |---|---|---|---|
   | id | String | ✅ | 壁纸 ID（客户端生成） |
   | title | String | | 标题 |
   | imageUrl | String | | 原图 URL（内置壁纸留空，用本地资源） |
   | thumbnailUrl | String | | 缩略图 URL |
   | category | String | | 自然风光/城市建筑/极简风格/动物萌宠/二次元插画 |
   | author | String | | 作者 |
   | uploadTime | Long | | 时间戳（毫秒，**必须 Long**，Integer 会溢出） |
   | tags | String | | 逗号分隔，如 `萌宠,治愈` |
   | ratingSum | Long | | 评分总分（**当前 UI 未使用**，保留字段以免 schema 不一致） |
   | ratingCount | Long | | 评分人数（同上） |

   > ⚠️ **不要**创建 `isFavorite`、`localImg` 字段——纯前端概念。
   > 云数据库控制台没有 Number 类型，数值字段一律 **Long**。

4. 安全规则：开发期设为 **所有用户可读写**（否则真机查询会报权限错误）。

> 若真机报 **Schema 配置错误(1008230002)**：把对象类型名改为 `Wallpaper`（与类名一致），
> 并删除 `Wallpaper.ets` 中 `naturalbase_ClassName()` 的重写。

> 📌 **云存储无需开通**：原"上传壁纸"功能已按需求移除，项目不再使用云存储。

### 第 4 步：编译

```powershell
$env:DEVECO_SDK_HOME = 'E:\DevEco Studio\sdk'
& 'E:\DevEco Studio\tools\node\node.exe' 'E:\DevEco Studio\tools\hvigor\bin\hvigorw.js' `
  --mode module -p module=entry@default -p product=default -p requiredDeviceType=phone `
  assembleHap --analyze=normal --parallel --incremental --daemon
```
看到 `BUILD SUCCESSFUL` 即通过（⚠️ hvigor 常以退出码 1 收尾，**以日志文本为准**）。

> 若报签名错误（`11014001 Key alias not found`）：
> `File → Project Structure → Signing Configs` → 勾选 **Automatically generate signature** → 登录华为账号。

## 三、运行与验证清单

> ⚠️ **云服务在模拟器/预览器上不可用**（华为限制），云相关必须真机验证；
> UI、收藏、内置壁纸、编辑导出在模拟器上也能验。
> ⚠️ 每次改完先**卸载旧包 → Clean → Run**，确认 `Install Successfully`，否则你看到的可能还是旧界面。

**数据层**
1. 首启（无缓存）→ 首页出现**骨架屏卡片**（不是纯黑）；
2. 杀掉进程再进 → 首屏**立刻**有图，无 loading 闪烁（本地缓存秒开）；
3. 滚到底部加载时开飞行模式 → 底部出现「加载失败，点击重试」；关飞行模式点它 → 能续上（**这是曾经永久锁死的路径**）；
4. 无网冷启动 → 顶部黄色离线提示条 + 内置壁纸，点「重试」可恢复。

**核心闭环**
5. 预览页点「设为锁屏」→ 系统相册写入 + 弹出图库设置引导卡片，点「复制步骤」提示已复制；
6. 预览页按**系统返回键** → 关闭预览回到首页（**不应退出 App**）；
7. 预览页点「✏️ 编辑」→ 改点东西（旋转/滤镜/加文字）→ 按返回键 → 弹「放弃编辑？」；
8. 编辑后保存成功 → 再按返回键 → 直接退出（不再追问）；
9. 编辑导出后，与预览对比：**字重、字号、阴影大小、贴纸角度**应一致。

> 📌 预览页底部有保存比例开关，两种都要验：
> **铺满屏幕**（默认）→ 相册里的图是**手机屏幕比例**、无黑边，与预览所见一致（设为壁纸不会被系统二次裁切）；
> **原图比例** → 相册里的图保持原图宽高比，完整不裁切。

**贴纸**
10. 工作台：贴 2 张贴纸 → 返回键 → 回选背景；再按返回 → 弹确认；
11. 画板：拖动贴纸后按返回 → 弹确认；保存成功后按返回 → 直接退出；删除角标应**贴在选中的那张贴纸上**。

**合规与收尾**
12. 我的 →「法律与关于」→ 三个 tab 均可开可滚，返回键能关；
13. 关于与版权 →「清除缓存」→ 提示清理了多少临时文件，**收藏必须仍在**；
14. 我的 → 关于我们 → 版本号是**实时读取**的（`1.0.0`），不是写死的旧值。

## 四、上架前检查清单（缺一项就可能被驳回）

- [ ] **主体信息**：`LegalDocPage` 的「关于与版权」里补齐**备案号 / 统一社会信用代码 / 开发者全称**（当前是占位文案）；
- [ ] **隐私政策生效日期**：把文案里的 `2026-01-01` 改成真实的生效日期（政策更新也要同步改）；
- [ ] **应用信息一致性**：`AppScope/app.json5` 的 `versionName/versionCode` 与实际发布版本一致（页面已改成实时读取，不会再出现文案与实际不符）；
- [ ] **权限声明**：`module.json5` 里**不要**声明 `ohos.permission.WRITE_IMAGEVIDEO`（声明了会安装失败 `9568289`；保存相册走 SaveButton 临时授权，无需声明）；
- [ ] **图片版权**：内置壁纸来自公开免费图库，已在内置文档中署名并给出侵权下架邮箱；**商用前请逐张确认授权范围**；
- [ ] **应用图标与截图**：`AppScope/resources` 图标、市场截图与介绍文案（文案里不要出现"一键设为壁纸"这类做不到的承诺）；
- [ ] **隐私标签**：AGC 后台按真实情况填写（本应用不采集个人数据）；
- [ ] **真机回归**：完成第三节 14 项验证。

## 五、已知取舍

- **"设为壁纸"的最后一步必须由用户在图库完成**：HarmonyOS NEXT 未向三方应用开放直接换壁纸的能力（`@ohos.wallpaper` 自 API 9 起废弃）。应用的做法是"保存到相册 + 给出步骤引导 + 可复制步骤"，**不承诺一键设置**；将来若系统开放，只需在 `SetWallpaperGuide` 里加能力探测即可平滑升级。
- **导出与预览的排版无法 100% 逐像素一致**：Canvas 没有"增量测宽"接口，且 ArkUI 断行规则不完全公开。CJK 短语、emoji（代理对安全）、英文整词已对齐；要 100% 一致只能改成截屏导出，但那会丢失原分辨率并带上灰边，故不采用。
- **内置壁纸为占位图**（picsum + 自有宠物图）：替换 `resources/base/media/` 下的图片与 `DefaultWallpapers.ets` 即可。
- **`ratingSum/ratingCount` 字段保留但 UI 未使用**：评分系统已按需求移除；字段保留是为了与云端 schema 一致（缓存 DTO 也会往返这两个字段，避免回写云端时被清零）。
- **缩略图**：客户端暂用原图 URL 充当缩略图；若后续图库变大，可用云函数生成缩略图。
- **历史遗留文件已清理**：7 个无调用方文件与 `DEPRECATED.md` 已于 2026-09-12 删除，工程已纳入 git 版本控制。
