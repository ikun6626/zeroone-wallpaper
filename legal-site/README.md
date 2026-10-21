# ZeroOne 壁纸 · 法务文档站

应用市场（AppGallery）要求提供**可公网访问的隐私政策 URL**。本目录是线上法务站点的源文件。

## 文件与线上地址

| 文件 | 内容 | 线上地址 |
|---|---|---|
| `index.html` | 隐私政策（AGC 后台填这个） | `https://www.gqscc.cn/legal/` |
| `terms.html` | 用户协议 | `https://www.gqscc.cn/legal/terms.html` |
| `about.html` | 关于与版权 / 图片来源 | `https://www.gqscc.cn/legal/about.html` |
| `self-check.html` | 审核自查说明（测试账号、流程、权限） | `https://www.gqscc.cn/legal/self-check.html` |
| `style.css` | 样式（纯静态，与 App 配色一致） | — |

页面为纯静态：无 JS、无 Cookie、无外部字体、无第三方统计。

## 部署

站点与主站同域，挂在 nginx 的 `/legal/` 路径下：

```bash
# 服务器（宝塔）示例
# 目标目录：/www/wwwroot/www.gqscc.cn/legal/
rsync -av --delete legal-site/ root@<server>:/www/wwwroot/www.gqscc.cn/legal/
```

`www.gqscc.cn` 使用 Let's Encrypt 证书，覆盖 `gqscc.cn` 与 `www.gqscc.cn`。
不要再用 `gqs.404.kim`（该域名当前指向其他站点且证书不匹配）。

## 与 App 的同步（重要）

**唯一文案源是 `entry/src/main/ets/common/constants/LegalTexts.ets`。**

改文案时必须同时同步：

1. `LegalTexts.ets`（应用内首次启动弹窗 + 法律与关于页）
2. 本目录 `index.html` / `terms.html` / `about.html`
3. 修改后把 `LEGAL_UPDATED_AT` 改为当天日期（会触发用户重新同意隐私政策）

当前产品事实（2026-10-21）：

- 在线内容 + 本地 295 张兜底；联网使用 `INTERNET`，触感反馈使用 `VIBRATE`。
- 浏览、收藏、编辑、贴纸创作免登录；**保存图片到相册必须登录**，支持注册。
- 收藏仅保存在本机，**暂不与账号收藏合并/同步**。
- 账号数据由开发者自建后端（NestJS + MySQL，中国境内）处理，密码只存不可逆哈希。
- 鸿蒙三方应用不能直接设置壁纸：保存到相册后，由用户在系统图库设置锁屏/桌面。

## 上线前检查

- [ ] `https://www.gqscc.cn/legal/` 打开是隐私政策正文，不是目录列表
- [ ] `/legal/terms.html`、`/legal/about.html` 可访问
- [ ] 页面顶部更新/生效日期为真实日期（当前 2026-10-21）
- [ ] 主体名称、App 备案号与 AGC 后台一致
- [ ] 应用内 `LegalTexts.ets` 与线上页面逐条一致
- [ ] 首次启动弹窗能读到隐私政策与用户协议全文
