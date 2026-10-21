# ZeroOne 壁纸 · 法务文档站

应用市场（AppGallery）提交时**必须提供可公网访问的隐私政策 URL**。这个目录就是那个站点。

## 文件

| 文件 | 内容 | 市场后台填哪个 |
|---|---|---|
| `index.html` | **隐私政策** | ✅ 填 `https://gqs.404.kim/` |
| `terms.html` | 用户协议 | 可选（应用内可达即可） |
| `about.html` | 关于与版权（含图片来源声明） | 可选 |
| `style.css` | 样式（深色，与 App 配色一致） | — |

页面是**纯静态**的：无 JS、无 Cookie、无外部字体、无第三方统计。审核时不会被判定为"收集访问者信息"。

---

## 上线前必须替换的 3 处

打开 `index.html` 搜 `待补充`，以及 `about.html` 里那段带 `⚠️ 给开发者` 的提示框：

| # | 位置 | 现在 | 要改成 |
|---|---|---|---|
| 1 | `index.html` 第十二节「主体名称」 | `ZeroOne` | 与备案主体一致（个人填真实姓名 / 企业填工商全称） |
| 2 | `index.html` 第十二节「应用备案号」 | `（待补充）` | 工信部下发的 App 备案号，形如 `京ICP备xxxxxxxx号-1A` |
| 3 | `about.html` 的 `⚠️ 给开发者` 提示框 | 有 | **整段删除**（那是给你看的，不能给用户看） |

> 另外：`index.html` / `terms.html` 顶部的「更新日期 / 生效日期」现在是 `2026-09-13`，
> 改成**真实生效日**（不能晚于提交审核日）。

---

## 部署到 `gqs.404.kim`

前提：你手上有 `404.kim` 这个域名的 DNS 管理权限。

### 方案 A：GitHub Pages（免费，推荐起步）

```powershell
# 1) 新建一个仓库（例如 zeroone-legal），把本目录 4 个文件推上去
cd E:\zeroone\legal-site
git init
git add .
git commit -m "ZeroOne 壁纸法务文档"
git remote add origin https://github.com/<你的用户名>/zeroone-legal.git
git push -u origin main

# 2) 仓库 → Settings → Pages → Source 选 main /(root) → Save

# 3) 在仓库根目录加一个 CNAME 文件（内容只有一行）
#    gqs.404.kim

# 4) 到 404.kim 的 DNS 管理后台加一条记录：
#    类型 CNAME   主机记录 gqs   记录值 <你的用户名>.github.io
```

等 DNS 生效（几分钟到几小时），然后到 Pages 设置里勾 **Enforce HTTPS**。

### 方案 B：Cloudflare Pages / Vercel（免费，国内访问通常更稳）

- Cloudflare Pages：新建项目 → 直接上传本目录 → 绑定自定义域 `gqs.404.kim`
- Vercel：`vercel --prod` 部署后 → Settings → Domains → 添加 `gqs.404.kim`

按提示在 DNS 加一条 CNAME 即可。

### 方案 C：你自己的国内服务器

```nginx
server {
    listen 443 ssl;
    server_name gqs.404.kim;
    root /var/www/zeroone-legal;
    index index.html;

    # 证书（用 acme.sh / certbot 申请）
    ssl_certificate     /etc/letsencrypt/live/gqs.404.kim/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/gqs.404.kim/privkey.pem;
}
```

> ⚠️ **国内服务器 + 这个域名需要 ICP 备案**，否则域名会被阻断。
> **方案 A / B 是境外托管，不需要给网站单独做 ICP 备案**，上线更快。
> （注意：这与你的 **App 备案是两回事**，App 备案无论如何都要办。）

---

## 本地预览

```powershell
cd E:\zeroone\legal-site
E:\Anaconda\python.exe -m http.server 8080
# 浏览器打开 http://127.0.0.1:8080
```

---

## 上线后自检清单

- [ ] `https://gqs.404.kim/` 能打开，且是**隐私政策**正文（不是目录列表）
- [ ] `https://gqs.404.kim/terms.html`、`/about.html` 都能打开
- [ ] **HTTPS 生效**（市场要求 https，不能是 http）
- [ ] 用手机 4G（非 WiFi）也能打开 —— 审核方可能用移动网络访问
- [ ] 页面里**没有** `待补充` / `⚠️ 给开发者` 等字样
- [ ] 主体名称、备案号与应用内《隐私政策》**一字不差**
- [ ] 顶部日期是真实生效日

---

## 与应用内的关系（重要）

本 App **不联网、零权限**，因此**应用内无法打开网页**。两边的分工是：

| 位置 | 作用 |
|---|---|
| 应用内《法律与关于》 | 用户随时可读（内置文本，离线可用）—— 满足"应用内可达"要求 |
| 本静态站点 | 提供给应用市场后台填写 URL 字段 |

**两边措辞必须一致。** 应用内文案在
`entry/src/main/ets/common/components/LegalDocPage.ets`，本目录的页面与它逐条对应。
改了一边记得同步另一边。
