# 已废弃代码清单（DEPRECATED）

> 本文件记录**没有任何调用方**的历史文件。它们保留在仓库里只为可回溯 —— 项目当前**没有版本控制（无 .git）**，
> 直接删除不可恢复，因此这里采用"加弃用横幅 + 建清单"的隔离方式，而不是删除。
>
> 如果你确认这些能力不再需要，告诉我，我可以一次性删除（建议先把仓库纳入 git 再删）。

## 清单

| 文件 | 行数级别 | 状态 | 为什么还在 | 替代方案 |
|---|---|---|---|---|
| `common/components/StickerCanvasComponent.ets` | ~230 | 无调用方 | 旧版"背景 + 单张贴纸"手势组件 | 贴纸编辑已由 `StickerStudioPage`（快照合成）+ `StickerBoardPage`（多贴纸画板）承担 |
| `common/sticker/StickerProcessor.ets` | ~100 | 无调用方 | 遮罩抠图（魔法棒涂抹）不再是主流程 | 工作台改为"选背景 + 贴纸自由摆放"；如需恢复智能抠图可复用，注意返回值由调用方 `release()` |
| `common/sticker/WallpaperExporter.ets` | ~185 | 无调用方 | 早期离屏合成导出器 | `common/editor/ImageComposer.composeToJpeg`（支持文字层/贴纸层/WYSIWYG 对齐） |
| `pages/PhotoEditorPage.ets` | ~245 | 无入口 | Phase-1 骨架页（"取消"空实现、"完成"仅 toast） | 全屏预览 → `ImageEditor` 已完整上线 |
| `common/photoeditor/model/EditState.ets` | ~120 | 无调用方 | 仅被 PhotoEditorPage 使用 | `ImageEditor` 的编辑状态 |
| `common/photoeditor/service/ImageRenderer.ets` | ~150 | 无调用方 | 仅被 PhotoEditorPage 使用 | `ImageEditor.loadOriginal`（但其 PixelMap 释放约定值得沿用） |
| `common/photoeditor/utils/CoordinateMapper.ets` | ~140 | 无调用方且 **未完成** | Phase-1 占位实现，TODO 未做（未考虑旋转/EXIF） | `CropGeometry` + `dispRect` 换算。**若复用必须先补完 TODO 并验证，否则导出裁切会错位** |

## 复核方法

```powershell
# 以 StickerCanvasComponent 为例：应只命中它自己的定义文件
rg "StickerCanvasComponent" entry/src/main/ets
rg "generateSticker|WallpaperExporter|PhotoEditorPage|CoordinateMapper" entry/src/main/ets
```

## 判断"死代码"的标准

1. 全工程 grep 只命中定义处（无 import、无 new、无 `$r` 引用）；
2. 页面类文件还要额外确认 `resources/base/profile/main_pages.json` 里没有注册路由
   （`PhotoEditorPage` 就不在其中，`main_pages.json` 只注册了 `pages/Index`）；
3. 注意区分"没人用"和"运行时通过字符串反射调用" —— 本项目不存在后者。
