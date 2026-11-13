# AGENTS.md

> 给 AI Agent / 协作者的项目约定。改代码前先读这一页，能省掉大部分返工。

## 一、事实来源的顺序

改任何东西之前，按这个顺序确认真实状态：

1. `CURRENT-STATE.md` —— 唯一现状基准（版本、上架状态、产品决策）
2. `PRD.md` —— 产品需求与交互规则
3. `CHANGELOG.md` —— 每次改动的时间倒序记录
4. `docs/` —— 单次迭代的设计与验收记录

**规则：产品状态发生变化时，先更新 `CURRENT-STATE.md`，再更新 PRD / 审计 / CHANGELOG。**
仓库里存在多个历史版本的描述（离线版 / 云端版 / 在线版），冲突时以 `CURRENT-STATE.md` 的时间戳为准，
不要拿旧文档当依据。

## 二、改动完成的标准

一次改动只有同时满足下面四条才算完成：

1. `hvigorw test` 通过（`entry/src/test` 下的用例全绿）
2. `hvigorw clean` + `assembleHap` 通过，无新增编译警告
3. 真机或模拟器上实际点过一遍相关路径，不是只看日志
4. 在 `CHANGELOG.md` 追加一条记录，写清「改了什么、怎么验证的、没做什么」

「没做什么」必须写。这条是防止下一轮把已排除的方案又做一遍。

## 三、绝对不能碰的东西

| 对象 | 规则 |
|---|---|
| `build-profile.json5` 的签名配置 | 不入库。签名材料（`.p12` / `.p7b` / `.cer`）与口令禁止提交 |
| `entry/src/main/resources/base/media/` | 已有素材不要改名或删除，`LocalWallpapers.ets` 的 id 与之绑定 |
| 收藏数据 | 本地 id 改动必须同步维护 `LocalWallpapers.DEDUP_ALIASES`，否则用户收藏丢失 |
| 隐私政策与权限声明 | 与 `CURRENT-STATE.md` 的联网形态保持一致，不得沿用离线版措辞 |

## 四、素材导入的固定流程

新增壁纸素材一律走 `tools/` 下的脚本，不手工往 `media/` 里拷文件：

```bash
# 1) 先看会做什么（零写入）
python tools/import_workbuddy_batch.py --csv docs/workbuddy-image-tags-final.csv \
    --batch <批次号> --expect <候选数> --dry-run

# 2) 再真跑；重复执行必须零写入（识别为 ALREADY_IMPORTED）
python tools/import_workbuddy_batch.py --csv docs/workbuddy-image-tags-final.csv \
    --batch <批次号> --expect <候选数>

# 3) 最后校验
python tools/verify_image_dedup.py
```

门槛：短边 ≥ 1080、比例 9:16~9:21、SHA-256 与 pHash（汉明 ≤ 6）双去重。
脚本必须幂等，重复执行不得产生新写入；写清单用临时文件 + `os.replace` 原子替换。

## 五、文案与交互红线

- 鸿蒙三方应用**不能**直接设置壁纸，文案只能是「保存到相册 + 引导去图库设置」，不许写「一键设置」
- 未登录点保存 → 弹登录 → 登录成功后回到原页面提示「请再次点击保存」，不能在同一回调里假装保存成功
- 不做会员、不做支付、不做用户上传

## 六、代码风格

- ArkTS 严格模式：不用 `any`，不用 `!` 断言压类型错误
- 注释用中文，写「为什么这样做」，不写「这一行在干什么」
- 网络层统一走 `common/net/`，不在页面里裸写 `http.createHttp()`
- 新增页面需在 `main_pages.json` 注册，否则白屏
