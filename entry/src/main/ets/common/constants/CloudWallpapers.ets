import { Wallpaper } from '../../model/Wallpaper';

/**
 * CloudWallpapers —— 云端壁纸种子数据
 *
 * 由 tools/prepare_cloud_assets.py --emit-seed 生成，**请勿手改**：
 * 加图后重跑脚本、再把生成的 SEED 列表替换进来即可。
 *
 * 用途：把这批素材一次性写进 AGC 云数据库 wallpapers 表。
 * imageUrl / thumbnailUrl 存的是**云存储路径**而不是完整链接 ——
 * 对象是私有的，显示时由 CloudStorageUtil.getDownloadURL() 换临时链接。
 *
 * SEED 每行格式：id|标题|分类|作者|上传时间(毫秒)|标签
 */
export class CloudWallpapers {
  private static readonly SEED: string[] = [
    '12019_sunset_2080072|日落|自然风光||1789002120426|自然风光,日落',
    '12659751_airplane_4252410|航班|自然风光||1788220168696|自然风光,航班',
    '5336885_japan_2418041|日本|城市建筑||1788220544554|城市建筑,日本',
    'adege_northern_lights_2989795|Northern|自然风光|adege|1788220274585|自然风光,northern',
    'andriish22_cat_4542301|猫咪|动物萌宠|andriish22|1788220424066|动物萌宠,猫咪',
    'anna_f_domestic_animal_5173354|Animal|动物萌宠|anna-f|1788220470431|动物萌宠,animal',
    'chiemseherin_chiemsee_lake_8523044|湖畔|自然风光|chiemseherin-chiemsee|1789002140009|自然风光,湖畔',
    'chiemseherin_milky_way_9767930|Milky|自然风光|chiemseherin|1788220139521|自然风光,milky',
    'couleur_rhodesian_ridgeback_2727035|Ridgeback|动物萌宠|couleur-rhodesian|1788220693166|动物萌宠,ridgeback',
    'david_pisnoy_zsczcf08k00_unsplash|Pisnoy|自然风光|david-pisnoy|1789002578201|待归类,pisnoy',
    'dendoktoor_basset_hound_7861037|Dendoktoor|自然风光|dendoktoor-basset|1788220495478|待归类,dendoktoor',
    'evgenit_milky_way_6496937|Milky|自然风光|evgenit|1788220149236|自然风光,milky',
    'fleuber_starry_sky_3640950|天空|自然风光|fleuber-starry|1788220245934|自然风光,天空',
    'garten_gg_knight_6691692|Night|自然风光|garten-gg|1788220581487|自然风光,night',
    'isakh_the_pointer_5352390|Pointer|自然风光|isakh-the|1788220851762|待归类,pointer',
    'jaclou_dl_shetland_sheepdog_8342397|狗狗|动物萌宠|jaclou-dl|1788220743242|动物萌宠,狗狗',
    'janus69_port_3585566|Port|城市建筑|janus69|1788220655554|城市建筑,port',
    'jillwellington_family_591581|Jillwellington|自然风光|jillwellington-family|1788220524404|待归类,jillwellington',
    'jofy88_fall_1051300_1920_1|Fall|自然风光|jofy88-fall|1788220677294|待归类,fall',
    'jofy88_fall_1051300|Fall|自然风光|jofy88-fall|1788220660850|待归类,fall',
    'kanenori_landscape_5278857|Landscape|自然风光|kanenori|1788220683916|自然风光,landscape',
    'kanenori_landscape_5361558|Landscape|自然风光|kanenori|1788220767623|自然风光,landscape',
    'kanenori_mountain_7826398|山峦|自然风光|kanenori|1788220804893|自然风光,山峦',
    'kidsnewshu_puli_5292660|Kidsnewshu|自然风光|kidsnewshu-puli|1788220602078|待归类,kidsnewshu',
    'leejongsung_sex_between_men_968663|Sun|自然风光|leejongsung-sex|1788220457034|自然风光,sun',
    'lightheartedlearning_lava_field_4700573|原野|自然风光|lightheartedlearning-lava|1788220711376|自然风光,原野',
    'louis_paulin_vx5b5ktftgs_unsplash|Paulin|自然风光|louis-paulin|1789017219683|待归类,paulin',
    'manuel_h_trees_7733877|Tree|自然风光|manuel-h|1788220183142|自然风光,tree',
    'mburleson_dogs_1582195|狗狗|动物萌宠|mburleson-dogs|1788220833142|动物萌宠,狗狗',
    'michael_pointner_road_8844555|Pointner|自然风光|michael_pointner-road|1789002108463|待归类,pointner',
    'n1ce_hhh8na_ghpy_unsplash|Ghpy|自然风光|n1ce-hhh8na_ghpy|1789002641171|待归类,ghpy',
    'pat_photographies_lake_5178829|湖畔|自然风光|pat_photographies|1788220802344|自然风光,湖畔',
    'pat_photographies_walnut_4306831|Photographies|自然风光|pat_photographies-walnut|1788220650637|待归类,photographies',
    'pexels_architecture_1846657|Architecture|城市建筑|pexels|1788220501805|城市建筑,architecture',
    'pexels_astronomy_1850461|Astronomy|自然风光|pexels-astronomy|1788220218451|待归类,astronomy',
    'pexels_aysegul_aytoren_46790226_13830385|Aysegul|自然风光|pexels-aysegul|1789017401802|待归类,aysegul',
    'pexels_chinarianphotographer_10624383|Chinarianphotographer|自然风光|pexels-chinarianphotographer|1789004985688|待归类,chinarianphotographer',
    'pexels_dog_face_1840069|狗狗|动物萌宠|pexels|1788220633697|动物萌宠,狗狗',
    'pexels_ocean_1867285|Ocean|自然风光|pexels|1789002087091|自然风光,ocean',
    'pexels_stars_1837306|Star|自然风光|pexels-stars|1788220127560|自然风光,star',
    'pexels_weimaraner_1869442|Weimaraner|自然风光|pexels-weimaraner|1788220509165|待归类,weimaraner',
    'piro4d_asian_4209448|Asian|自然风光|piro4d-asian|1788220466030|待归类,asian',
    'pok_rie_sunset_1637376|日落|自然风光|pok_rie|1789002099252|自然风光,日落',
    'promo25_milky_way_559641|Milky|自然风光|promo25|1788220202726|自然风光,milky',
    'radfotosonn_siberian_sword_lily_7214720|Radfotosonn|自然风光|radfotosonn-siberian|1788220731007|待归类,radfotosonn',
    'rafael_hoyos_weht_upx8njhjzbo_unsplash|Rafael|自然风光|rafael-hoyos|1789002625149|待归类,rafael',
    'rolaman_welsh_terrier_5278572|Rolaman|自然风光|rolaman-welsh|1788220700869|待归类,rolaman',
    'saundelr_tree_7010442|Tree|自然风光|saundelr|1788220289854|自然风光,tree',
    'tae_wook_republic_of_korea_1877033|Republic|自然风光|tae_wook-republic|1788220736263|待归类,republic',
    'tingyaoh_city_view_1698285|城市|城市建筑|tingyaoh|1788220787960|城市建筑,城市',
    'zebulon72_bridge_961766|Bridge|城市建筑|zebulon72|1788220844540|城市建筑,bridge',
  ];

  /** 展开成 Wallpaper 记录（云存储路径按约定拼好） */
  static all(): Wallpaper[] {
    const out: Wallpaper[] = [];
    for (let i = 0; i < CloudWallpapers.SEED.length; i++) {
      const f: string[] = CloudWallpapers.SEED[i].split('|');
      const id: string = f[0];
      out.push(new Wallpaper(id, f[1],
        `wallpapers/${id}.jpg`, `thumbs/${id}_thumb.jpg`,
        f[2], f[3], parseInt(f[4], 10), f[5]));
    }
    return out;
  }
}
