import { Wallpaper } from '../../model/Wallpaper';

/**
 * DefaultWallpapers —— 内置默认壁纸数据（冷启动兜底数据）+ 预置标签
 *
 * 分类体系（5 个核心分类）：
 *   自然风光 / 城市建筑 / 极简风格 / 动物萌宠 / 二次元插画
 * 标签体系：
 *   14 个预置标签（上传时可多选、筛选时使用）
 *
 * 内置壁纸 = 10 张网络壁纸（picsum 图源 + 本地兜底图）+ 4 张猫咪 + 8 张狗狗 = 22 张；
 * 其中 my_cat、my_dog 前缀的 12 张为纯本地图（imageUrl 置空）
 */
export class DefaultWallpapers {
  /** 核心分类（全部 = 不过滤） */
  static readonly CATEGORIES: string[] = ['全部', '自然风光', '城市建筑', '极简风格', '动物萌宠', '二次元插画'];

  /** 预置标签表（上传时可多选；标签同时用于筛选与精选集合） */
  static readonly PRESET_TAGS: string[] = [
    '星空', '科幻太空', '暗色', '治愈', '清新', '赛博朋克', '国风',
    '萌宠', '风景', '城市夜景', '简约', '插画', '梦幻', '暖色'
  ];

  /** 内置默认壁纸（纯本地图为主） */
  static readonly ALL: Wallpaper[] = [
    // ===== 自然风光 =====
    new Wallpaper(
      'wf_nature_01', '星空·银河之眼', 'https://picsum.photos/seed/zeroone_nature01/720/1280',
      'https://picsum.photos/seed/zeroone_nature01/360/640', '自然风光', '青衫客', 1700000000000, '星空,暗色,梦幻'
    ),
    new Wallpaper(
      'wf_nature_02', '森语·晨雾', 'https://picsum.photos/seed/zeroone_nature02/720/1280',
      'https://picsum.photos/seed/zeroone_nature02/360/640', '自然风光', '折柳', 1700003600000, '风景,治愈,清新'
    ),
    // ===== 城市建筑 =====
    new Wallpaper(
      'wf_city_01', '都市·霓虹夜', 'https://picsum.photos/seed/zeroone_city01/720/1280',
      'https://picsum.photos/seed/zeroone_city01/360/640', '城市建筑', '空岛', 1700007200000, '城市夜景,赛博朋克,暗色'
    ),
    new Wallpaper(
      'wf_city_02', '天际·云端之上', 'https://picsum.photos/seed/zeroone_city02/720/1280',
      'https://picsum.photos/seed/zeroone_city02/360/640', '城市建筑', '铁盒', 1700010800000, '城市夜景,简约'
    ),
    // ===== 极简风格 =====
    new Wallpaper(
      'wf_minimal_01', '极简·一色', 'https://picsum.photos/seed/zeroone_minimal01/720/1280',
      'https://picsum.photos/seed/zeroone_minimal01/360/640', '极简风格', '团子', 1700014400000, '简约,清新,暖色'
    ),
    new Wallpaper(
      'wf_minimal_02', '几何·留白', 'https://picsum.photos/seed/zeroone_minimal02/720/1280',
      'https://picsum.photos/seed/zeroone_minimal02/360/640', '极简风格', '奶盖', 1700018000000, '简约,插画'
    ),
    // ===== 动物萌宠 =====
    new Wallpaper(
      'wf_pet_01', '萌宠·软糖喵', 'https://picsum.photos/seed/zeroone_pet01/720/1280',
      'https://picsum.photos/seed/zeroone_pet01/360/640', '动物萌宠', '桃子酱', 1700021600000, '萌宠,治愈'
    ),
    new Wallpaper(
      'wf_pet_02', '萌宠·兔兔星球', 'https://picsum.photos/seed/zeroone_pet02/720/1280',
      'https://picsum.photos/seed/zeroone_pet02/360/640', '动物萌宠', '布丁', 1700025200000, '萌宠,梦幻,治愈'
    ),
    // ===== 二次元插画 =====
    new Wallpaper(
      'wf_anime_01', '插画·幻境少女', 'https://picsum.photos/seed/zeroone_anime01/720/1280',
      'https://picsum.photos/seed/zeroone_anime01/360/640', '二次元插画', '江晚吟', 1700028800000, '插画,梦幻,暗色'
    ),
    new Wallpaper(
      'wf_anime_02', '插画·赛博猫娘', 'https://picsum.photos/seed/zeroone_anime02/720/1280',
      'https://picsum.photos/seed/zeroone_anime02/360/640', '二次元插画', '零号机师', 1700032400000, '插画,赛博朋克,科幻太空'
    ),
    // ===== 用户自加：猫咪壁纸（纯本地图；红底/模糊的已删除） =====
    new Wallpaper('my_cat_01', '我的萌宠·01', '', '', '动物萌宠', '我', 1700033000000, '萌宠,治愈'),
    new Wallpaper('my_cat_02', '我的萌宠·02', '', '', '动物萌宠', '我', 1700033600000, '萌宠,清新'),
    new Wallpaper('my_cat_04', '我的萌宠·04', '', '', '动物萌宠', '我', 1700034800000, '萌宠,梦幻'),
    new Wallpaper('my_cat_06', '我的萌宠·06', '', '', '动物萌宠', '我', 1700036000000, '萌宠,清新'),
    // ===== 用户自加：狗狗壁纸（纯本地图；模糊的已删除） =====
    new Wallpaper('my_dog_01', '萌犬·哈士奇', '', '', '动物萌宠', '我', 1700037000000, '萌宠,风景'),
    new Wallpaper('my_dog_03', '萌犬·恩特勒布赫', '', '', '动物萌宠', '我', 1700038200000, '萌宠,清新'),
    new Wallpaper('my_dog_04', '萌犬·蝴蝶犬', '', '', '动物萌宠', '我', 1700038800000, '萌宠,梦幻'),
    new Wallpaper('my_dog_05', '萌犬·马尔济斯', '', '', '动物萌宠', '我', 1700039400000, '萌宠,治愈'),
    new Wallpaper('my_dog_06', '萌犬·可卡布', '', '', '动物萌宠', '我', 1700040000000, '萌宠,清新'),
    new Wallpaper('my_dog_07', '萌犬·马尔济斯2', '', '', '动物萌宠', '我', 1700040600000, '萌宠,梦幻'),
    new Wallpaper('my_dog_08', '萌犬·边境柯利', '', '', '动物萌宠', '我', 1700041200000, '萌宠,风景'),
    new Wallpaper('my_dog_09', '萌犬·西里汉姆', '', '', '动物萌宠', '我', 1700041800000, '萌宠,治愈')
  ];

  /**
   * id → 本地图片资源名映射（media 目录下文件名去掉扩展名）
   *
   * ⚠️ 想自己加图时：把图片放进 resources/base/media/ 后，
   *   在这里加一行映射 + 在 ALL 数组加一条记录即可，旧图不用动。
   */
  private static readonly LOCAL_IMG: Record<string, string> = {
    'wf_nature_01': 'default_wallpaper_01',
    'wf_nature_02': 'default_wallpaper_02',
    'wf_city_01': 'default_wallpaper_03',
    'wf_city_02': 'default_wallpaper_04',
    'wf_minimal_01': 'default_wallpaper_05',
    'wf_minimal_02': 'default_wallpaper_06',
    'wf_pet_01': 'default_wallpaper_07',
    'wf_pet_02': 'default_wallpaper_08',
    'wf_anime_01': 'default_wallpaper_09',
    'wf_anime_02': 'default_wallpaper_10',
    'my_cat_01': 'custom_cat_01',
    'my_cat_02': 'custom_cat_02',
    'my_cat_04': 'custom_cat_04',
    'my_cat_06': 'custom_cat_06',
    'my_dog_01': 'custom_dog_01',
    'my_dog_03': 'custom_dog_03',
    'my_dog_04': 'custom_dog_04',
    'my_dog_05': 'custom_dog_05',
    'my_dog_06': 'custom_dog_06',
    'my_dog_07': 'custom_dog_07',
    'my_dog_08': 'custom_dog_08',
    'my_dog_09': 'custom_dog_09'
    // 例：'my_custom_01': 'custom_01'   ← 新加的图在这里登记
  };

  /**
   * 获取内置默认壁纸的本地兜底图资源（仅内置壁纸有值；云端壁纸返回 undefined）
   * @param id 壁纸 ID
   */
  static getLocalImg(id: string): Resource | undefined {
    const name: string | undefined = DefaultWallpapers.LOCAL_IMG[id];
    if (name === undefined || name.length === 0) {
      return undefined;
    }
    return $r(`app.media.${name}`);
  }
}
