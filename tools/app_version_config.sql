-- 2026-10-25 配置 harmony 版本记录：
-- versionCode=1002000 与线上在架版本一致 → 1.2.0 用户 needUpdate=false 静默；
-- 1.1.0 及更早用户会收到「立即更新」引导（正确行为，应用市场当前就是 1.2.0）。
-- 1.3.0 过审后：UPDATE 本行 version_name='1.3.0', version_code=1003000, update_content=...
INSERT INTO app_versions (platform, version_name, version_code, update_content, download_url, force_update, enabled, created_at)
VALUES ('harmony', '1.2.0', 1002000, '图库搜索与筛选、Cuto 风格首页、每日精选优化、保存登录门槛', 'https://appgallery.huawei.com/app/detail?id=com.zeroone.wallpaper', 0, 1, NOW());
