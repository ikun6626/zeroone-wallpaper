# WorkBuddy 图片标签成品交接

> 交接日期：2026-11-07
> 数据来源：WorkBuddy 已于 2026-11-05 完成的图片识别成品
> 项目内副本：`docs/workbuddy-image-tags-final.csv`

## 结论

现成标签数据已经拿到并复制进项目。TRAE 直接读取项目内副本即可，不需要重新调用 WorkBuddy 识图。

## 数据核验

| 项目 | 实际值 |
|---|---|
| 数据行数 | 2075 |
| 唯一 `relative_path` | 2075 |
| `tag_source=vision` | 2075 |
| 空 `tags` | 0 |
| 标签 JSON 可解析率 | 100%（0 条解析失败） |
| 每图标签数 | 3–8，平均 6.33 |
| 类目数 | 12 |
| 文件大小 | 357083 bytes |
| SHA-256 | `FCBF38F0BD2DB47C564712339A680C970F934A56C6F0D0DE9F797122689B5800` |

项目内副本与 WorkBuddy 原文件 SHA-256 完全一致。

## 字段

```text
relative_path,folder,category,format,width,height,tags,characters,tag_source
```

- `relative_path`：图片在素材根目录下的相对路径
- `folder`：来源文件夹
- `category`：WorkBuddy 旧 12 类分类
- `format`、`width`、`height`：图片格式与尺寸
- `tags`：JSON 数组形式的自由标签
- `characters`：角色/IP 记录字段，本次成品为空
- `tag_source`：本次 2075 行全部为 `vision`

## 使用边界

这份数据是 WorkBuddy 的既有成品，保持原样交接。它与 `产品改进方案-五项.md` 阶段一“每图 1–4 个中文自由词、无颜色词”的新口径并不完全一致：

- 当前每图为 3–8 个标签；
- 当前使用 12 个旧类目；
- 部分标签包含颜色或旧体系的描述词。

因此，TRAE 可以将它作为现有图片标签数据、联调样本或迁移输入使用，但不得声称它已经符合阶段一新口径，也不得直接用旧 12 类代替最新文档中的 11 个现有类目、白名单或 staging 验收。

## TRAE 读取方式

优先读取：

```text
E:\zeroone\docs\workbuddy-image-tags-final.csv
```

核对时至少验证：

1. UTF-8 CSV 可解析；
2. 行数为 2075；
3. `relative_path` 唯一；
4. `tags` 字段可作为 JSON 数组解析；
5. 不修改该 CSV 原文件。
