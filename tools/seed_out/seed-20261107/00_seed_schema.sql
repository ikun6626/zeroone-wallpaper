-- ZeroOne 种子数据：结构（MySQL 8；只执行一次，列已存在则跳过该行）
ALTER TABLE wallpapers ADD COLUMN is_seed TINYINT(1) NOT NULL DEFAULT 0;
ALTER TABLE wallpapers ADD COLUMN seed_batch VARCHAR(32) NOT NULL DEFAULT '';
CREATE INDEX idx_wallpapers_seed_batch ON wallpapers (seed_batch);
