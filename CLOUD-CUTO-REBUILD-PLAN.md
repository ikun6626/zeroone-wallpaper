# 云端版 + Cuto 风格重做方案

> 创建于 2026-09-30。状态:待用户审核。落地后每完成一步在 `CHANGELOG.md` 追加一段(沿用现有 CHANGELOG 风格)。

## Context(为什么做这次重做)

当前 ZeroOne 壁纸 App 经历过「云端版 → 全离线版」的回退,现已重新接回 Z 盘后台(`module.json5` L36-39 的 INTERNET 权限已恢复,`AlbumsApi.ets` / `DailyApi.ets` 已接 `/api/v1/albums`、`/home/composition`、`/colors`、`/albums/:slug`、`/daily/featured`)。但首页仍是离线时代的「纵向 List + 单列大卡 + 宠物优先重排 + 期号徽标」结构,既不简约也不高级,且无横向滑动。

用户要求对标苹果商城 Cuto 壁纸 App:
- 首页 = 当日新图 Hero 大卡,**右滑看昨天**(按日期切换)
- 「合辑」Tab 改名「图库」,3 列网格 + Cover 卡 + 居中白色分类名 + 暗色遮罩
- 底部 Tab emoji 改系统符号(SymbolGlyph),对齐已立项的「图标统一方案」
- 视觉极简:纯黑背景、留白充足、扁平化、无阴影

预期结果:首页一眼是 Cuto 式大图 + 横滑切换;图库一眼是抽象分类的 3 列彩色卡;Tab 干净无 emoji。后端零改动(复用现有合辑接口)。

---

## 一、后端改造(零代码改动,仅运营配置)

### 核心结论:不需要新增历史精选接口

`Z:\zeroone管理后台\backend\src\modules\albums\albums.service.ts` 的 `resolveRule`(L336-358)在 `rule.source === 'daily'` 时已直接读 `daily_featured` 表最近 N 期(按 `date desc, issueNo desc`)。也就是说,只要后台有一条 `source='daily'` 的合辑,`GET /api/v1/albums/daily?page=1&pageSize=14` 就返回最近 14 期历史精选。

App 端 `AlbumsApi.fetchAlbumPage('daily', 1, 14)`(`AlbumsApi.ets` L216-248)已就绪,`toWallpaper`(L251-271)已正确处理 `issueNo/date/subtitle`,id=`daily_${issueNo}`。

### 阻塞前置项(运营在后台「合辑管理」页手动建)

| 字段 | 值 | 说明 |
|---|---|---|
| name | 每日精选 | 显示名 |
| slug | daily | URL 路径段 |
| rule | `{"source":"daily"}` | 触发 resolveRule 的 daily 分支 |
| limitCount | ≥ 14 | `detailForApp` L255 先取全集再 slice,必须 ≥ 想看的期数 |
| showOnHome | false | 避免与首页 Hero Swiper 重复占用合辑位 |
| enabled | true | App 才能拉到 |

**联调前必须确认这条合辑已建好**,否则首页 Hero 拉空。

### 不做的事

- 不新增 `GET /api/v1/daily/history`(复用合辑接口即可)
- 不改 `GET /api/v1/home/composition`(它仍只返回最新一期,App 端改为直接调合辑接口;`homeComposition.dailyFeatured` 可选保留给顶部徽标)
- 不动 prisma schema / migrations

### 可选优化(本期不做)

让 `/api/v1/home/composition` 一次性返回最近 14 期数组,省掉 App 端的第二次请求。当前一次请求 14 条数据量很小,不必现在做。

---

## 二、App 端逐文件改动

### 1. `entry\src\main\ets\pages\HomePage.ets`(大改,非整页重写)

**保留**:`dailyHeroCard` Builder 的视觉骨架(L396-465)改造成 Swiper item;`ImagePreview` 全屏预览复用;三态(骨架/错误/空)保留;`Haptics` 触感保留。

**删除**:
- `buildPetFirstList`(L119-142)—— 宠物优先语义与「按日期」冲突,直接删,`applyWallpapers` 改为原序赋值
- `homeDaily` 单期变量(L77)—— 改为 `@State heroItems: Wallpaper[]`
- `issueLabel` 里基于 `dailyFeatured` 的分支(L168-174)—— 改为基于 heroItems 第一项的日期

**新增**:
- `@State heroItems: Wallpaper[]` —— Hero Swiper 数据源
- `@State heroIndex: number = 0` —— 当前 Hero 索引
- `albumDs: WallpaperDataSource` 复用 —— 推荐合辑横滚(或新建 `AlbumBrief` 数据源)

**`aboutToAppear` 改造**:
```
AlbumsApi.fetchAlbumPage('daily', 1, 14).then((p: AlbumPage) => {
  this.heroItems = p.items;
  // 兜底:heroItems 空时显示重试态
});
// 推荐合辑仍用 fetchHomeComposition().albums 或 fetchAlbums()
```

**新 `build()` 骨架**:
```
Column() {
  // 顶部:Logo(左)+ 金色 Plus 胶囊(右),无大标题
  Row() {
    Text('ZeroOne').fontColor('#F2F2F5').fontSize(17).fontWeight(FontWeight.Bold)
    Blank()
    Text('升级 Plus').fontColor('#1A1A1A').backgroundColor('#F0D08A')
      .borderRadius(14).padding({left:12,right:12,top:6,bottom:6})
  }.height(44).padding({left:16,right:16})

  // Hero Swiper(占屏 60%)
  Swiper() {
    ForEach(this.heroItems, (w: Wallpaper) => {
      Stack({alignContent: Alignment.BottomStart}) {
        RemoteImage({ url: w.imageUrl, fit: ImageFit.Cover })
          .width('100%').height('100%')
        // 左上 ◎ 靶心(仅第一张显示)
        if (this.heroItems[0] === w) {
          Text('◎').fontColor('#FFFFFF').fontSize(20).position({x:16,y:16})
        }
        // 左下日期 + 副标题(暗色遮罩)
        Column({space:4}) {
          Text(this.fmtDate(w.uploadTime)).fontColor('#FFFFFF').fontSize(22).fontWeight(FontWeight.Bold)
          if (w.title.length > 0) { Text(w.title).fontColor('#E0E0E0').fontSize(13) }
        }.alignItems(HorizontalAlign.Start).padding(16)
      }.width('100%').height('100%').borderRadius(28).clip(true)
      .onClick(() => this.openPreview(w))
    }, (w: Wallpaper) => w.id)
  }
  .index(this.heroIndex).indicator(false).loop(false).duration(320)
  .itemSpace(15).vertical(false)
  .width('100%').layoutWeight(60)

  // 推荐合辑横滚
  Row() {
    Text('推荐合辑').fontColor('#F2F2F5').fontSize(17).fontWeight(FontWeight.Bold)
    Blank()
    Text('更多 >').fontColor('#A8A8B5').fontSize(13)
  }.padding({left:16,right:16,top:16,bottom:8})
  List({space:10}) {
    LazyForEach(this.albumDs, (a: AlbumBrief) => {
      ListItem() { this.albumMiniCard(a) }  // 120x160 横向卡
    }, (a: AlbumBrief) => a.slug)
  }.listDirection(Axis.Horizontal).padding({left:16,right:16})

  // 三态(骨架/错误/空)保留
}
```

**Hero 点图进预览**:daily 项 `wallpaper` 字段为 null(没关联真实壁纸 id),只能展示不能保存。保持 `promptAction.showToast({message:'这一期精选暂不支持保存'})` 即可。若后台 daily 行填了 `wallpaperId`,则关联真实壁纸可保存(`AlbumsApi.toLinkedWallpaper` 已处理)。

### 2. `entry\src\main\ets\pages\CategoryPage.ets`(中改)

**列表 Grid 改 3 列**:`columnsTemplate('1fr 1fr')` → `'1fr 1fr 1fr'`(约 L542);`albumGridHeight` 重算(3 列高度比 2 列矮)。

**合辑卡换 Cuto 风格**:删 `collectionCard` 旧 Builder,新写:
```
@Builder collectionCard(a: AlbumBrief) {
  Stack({alignContent: Alignment.Center}) {
    RemoteImage({ url: a.coverUrl, fit: ImageFit.Cover }).width('100%').height('100%')
    // 暗色遮罩
    Column().width('100%').height('100%')
      .linearGradient({angle:180, colors:[['#00000000',0.5],['#CC000000',1]]})
    // 居中白色分类名
    Text(a.name).fontColor('#FFFFFF').fontSize(13).fontWeight(FontWeight.Medium)
  }.aspectRatio(3/4).borderRadius(10).clip(true)
  .onClick(() => this.openAlbum(a))
}
```

**详情页保持不变**(已是 3 列 Grid,L611),只把列表页顶部标题「合辑」改「图库」(约 L490)。详情页标题保持合辑名。

### 3. `entry\src\main\ets\pages\Index.ets`(小改)

- **L65 `tabLabels`**:`['首页','合辑','贴纸','我的']` → `['首页','图库','贴纸','我的']`
- **L63 emoji → SymbolGlyph**:删 `tabIcons` 数组,`tabBarBuilder` 改:
```
@Builder tabBarBuilder(index: number) {
  Column({space:2}) {
    SymbolGlyph(this.currentIndex === index ? $r('sys.symbol.house_fill') : $r('sys.symbol.house'))
      .fontColor([this.currentIndex === index ? '#F0D08A' : '#A8A8B5'])
      .fontSize(22)
    Text(this.tabLabels[index]).fontSize(10)
      .fontColor(this.currentIndex === index ? '#F0D08A' : '#A8A8B5')
  }.width('100%').height('100%').justifyContent(FlexAlign.Center)
}
```
- **图标候选**(DevEco Symbol Library 面板搜存在性;保底用 ImagePreview.ets L612-668 已用过的名字):

| Tab | 主选 | 备选 |
|---|---|---|
| 首页 | `sys.symbol.house` | `sys.symbol.square` |
| 图库 | `sys.symbol.square_grid_2x2` | `sys.symbol.photo_on_rectangle` |
| 贴纸 | `sys.symbol.paw` | `sys.symbol.sparkles`(paw 找不到时用) |
| 我的 | `sys.symbol.person` | `sys.symbol.person_circle` |

### 4. `entry\src\main\ets\common\constants\LocalWallpapers.ets`(只修重复分类)

**重要:不要砍到 6-8 条**。`StickerStudioPage.ets` L318 用 `LocalWallpapers.ALL` 选编辑背景,L720 用 `getThumb`;`MinePage.ets` L119 用 `CATEGORIES.length - 1` 算 FAQ 数。砍掉会破坏编辑器壁纸库。

**只做一处小修**:L19 `CATEGORIES` 的重复项 `'自然风景','自然风景'` → 去重保留一项。

**离线兜底策略**:首页 Hero 接口失败 / 图库接口失败时,直接显示黑底 + 重试图标(不依赖 295 条内置图)。现有 `CategoryPage.localAlbums` 兜底逻辑保留,首页新增 `heroItems` 空时的重试态。

---

## 三、实施顺序(每步对应 CHANGELOG 一段)

1. **后端运营前置**(无代码):后台建 `daily` 合辑(`source='daily'`,limitCount≥14)。CHANGELOG 记「数据准备」段。
2. **`LocalWallpapers.ets` 修 CATEGORIES 重复**(独立小改,可独立验证)。
3. **`Index.ets` 改 Tab 名 + SymbolGlyph**(独立小改,可独立验证)。
4. **`CategoryPage.ets` 列表改 3 列 + Cuto 卡风格**(独立验证)。
5. **`HomePage.ets` Hero Swiper + 推荐合辑横滚**(依赖第 1 步联调)。
6. **联调验证 + 写 CHANGELOG 总结段**。

**可并行**:第 2、3、4 步相互独立,可并行。第 5 步依赖第 1 步。

---

## 四、风险点与回退

### 1. Swiper 在项目无范例(项目里 grep 无 Swiper 用法)

ArkTS Swiper 最小写法(已验证 API):
```
Swiper() {
  ForEach(this.heroItems, (w: Wallpaper) => {
    Stack() { /* Hero 卡 */ }.width('100%').height('100%')
  }, (w: Wallpaper) => w.id)
}
.index(this.heroIndex)
.indicator(false)       // 关底部圆点
.loop(false)            // 不循环:14 张按日期顺序
.duration(320)
.itemSpace(15)          // 右侧露边 ~15px(Cuto 风格关键)
.onChange((i: number) => { this.heroIndex = i; })  // 单参数,不是 onScrollIndex
.vertical(false)
```
约束:
- Swiper 必须父容器给高度,`layoutWeight(60)` 在 Column 里生效
- **ArkTS Swiper 用 `onChange(index: number)` 单参数**,不要写成 `onScrollIndex(first, last)`
- `indicator` 默认 true 会显示底部圆点,务必关
- 14 张大图性能:RemoteImage 已有三级缓存,Swiper 默认只渲染当前 ±1,无压力

### 2. SymbolGlyph 名字验证

DevEco Studio → 右侧资源面板 → System Symbol → 搜名字预览。保底安全名(已在 ImagePreview.ets 用过):`house / square / photo / heart / sparkles / person / circle`。贴纸 Tab 的 `paw` 找不到概率较高,备选 `sparkles`。

### 3. Tab 切换丢失首页 Swiper 状态

Swiper 走 Tabs 模式默认销毁子页重建。如需保留状态,首页 `aboutToAppear` 把 `heroItems` 缓存到 AppStorage,重建时直接读。本期可不做(每次重拉 14 条开销很小)。

### 4. LocalWallpapers 不砍的副作用

295 条内置图会让包体偏大(每张 1440 长边 + 720 thumb)。本期接受。后续若要瘦身,需先把 `StickerStudioPage` 的背景选择改为接云端 `AlbumsApi.fetchAlbumPage`,工程量翻倍,不在本期范围。

---

## 五、验证方法

| 步骤 | 验证方式 |
|---|---|
| 后端 daily 合辑 | `curl "http://localhost:3000/api/v1/albums/daily?page=1&pageSize=14"` 返回 14 条带 issueNo/date 的项 |
| Index Tab | 编译运行,4 个 Tab 显示 SymbolGlyph 图标,选中态金色 `#F0D08A`,文字「图库」 |
| CategoryPage | 编译运行,合辑列表 3 列,Cover 铺满 + 居中白名 + 暗色遮罩 |
| HomePage Hero | 编译运行,首页大卡 Swiper,右滑露边 15px,日期文字叠底,左上 ◎ 靶心(仅首张) |
| 兜底断网 | 关网络重启,Hero 显示空 + 重试图标,不白屏 |
| 编辑器回归 | 进 StickerStudioPage 选背景,壁纸库仍能滚动选图(验证 LocalWallpapers 未被破坏) |

---

## 六、关键文件清单

- `e:\zeroone\entry\src\main\ets\pages\HomePage.ets`(大改)
- `e:\zeroone\entry\src\main\ets\pages\Index.ets`(小改:Tab 名 + SymbolGlyph)
- `e:\zeroone\entry\src\main\ets\pages\CategoryPage.ets`(中改:3 列 + Cuto 卡)
- `e:\zeroone\entry\src\main\ets\common\constants\LocalWallpapers.ets`(小改:修重复分类)
- `e:\zeroone\entry\src\main\ets\common\net\AlbumsApi.ets`(复用,不改)
- `e:\zeroone\entry\src\main\ets\common\components\RemoteImage.ets`(复用,不改)
- `e:\zeroone\entry\src\main\ets\common\components\ImagePreview.ets`(复用,SymbolGlyph 写法参考 L612-668)
- `Z:\zeroone管理后台` 后台「合辑管理」页(运营建 daily 合辑,无代码改动)

---

## 七、不做的事(明确边界)

- 不新增后端接口(复用合辑接口)
- 不改 prisma schema / migrations
- 不砍 LocalWallpapers 的 295 条内置图(StickerStudioPage 依赖)
- 不改 StickerStudioPage / MinePage / ImageEditor(本期只动首页/图库/Index)
- 不做「图标统一方案」的完整落地(本期只改 Tab 4 个图标,其它页 emoji 后续)
- 不做 Plus 会员功能(顶部金色胶囊只视觉占位,无实际逻辑)
