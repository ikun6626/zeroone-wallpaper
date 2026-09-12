import matrix4 from '@ohos.matrix4';
import { image } from '@kit.ImageKit';
import { componentSnapshot, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { PixelScope } from '../common/utils/PixelScope';
import { EditGuard } from '../common/utils/EditGuard';

/**
 * 贴纸项：@Observed 使字段修改能被 @ObjectLink 子组件感知
 * 只存资源名字符串，渲染时再转 $r（避免 Resource 进状态对象）
 */
@Observed
class StickerItem {
  id: number = 0;
  mediaName: string = '';
  posX: number = 80;   // 贴纸左上角偏移（vp）
  posY: number = 120;
  zoom: number = 1;    // 缩放
  angle: number = 0;   // 旋转角度（绕贴纸中心）
  constructor(id: number, mediaName: string) {
    this.id = id;
    this.mediaName = mediaName;
  }
}

/** 单张贴纸节点：@ObjectLink 观察 + Pan/Rotation/Pinch + 虚线选中框 */
@Component
struct StickerNode {
  @ObjectLink item: StickerItem;
  @Prop selected: boolean = false;
  onSelect: (id: number) => void = () => {};
  onDirty: () => void = () => {};
  onDelete: () => void = () => {};

  private readonly baseSize: number = 140;
  private basePosX: number = 0;
  private basePosY: number = 0;
  private baseAngle: number = 0;
  private baseZoom: number = 1;

  /**
   * 删除角标的反向缩放系数
   * 角标挂在贴纸节点内（才能跟着贴纸走），但父节点带 zoom 变换：
   * 不做补偿的话，贴纸缩到 0.4 倍时角标只有 12px，根本点不中。
   */
  private badgeScale(): number {
    return this.item.zoom > 0 ? 1 / this.item.zoom : 1;
  }

  /** 中心变换矩阵：平移(中心) × 旋转 × 缩放 × 平移(-w/2,-h/2) */
  private m() {
    const h: number = this.baseSize / 2;
    return matrix4.identity()
      .translate({ x: this.item.posX + h, y: this.item.posY + h, z: 0 })
      .rotate({ x: 0, y: 0, z: 1, angle: this.item.angle })
      .scale({ x: this.item.zoom, y: this.item.zoom, z: 1 })
      .translate({ x: -h, y: -h, z: 0 });
  }

  build() {
    Stack() {
      // 选中虚线高亮框
      if (this.selected) {
        Column()
          .width(this.baseSize)
          .height(this.baseSize)
          .border({ width: 1.5, color: '#FF6B6B', style: BorderStyle.Dashed })
          .borderRadius(6)
      }
      // 贴纸图（资源名 → $r 运行时解析）
      Image($r(`app.media.${this.item.mediaName}`))
        .width(this.baseSize)
        .height(this.baseSize)
        .objectFit(ImageFit.Contain)

      // 删除角标：挂在贴纸自己身上（此前挂在画板固定位置，
      // 选中画面上方的贴纸时，删除按钮还停在底部，容易误删/找不到）。
      // 反向缩放保持点击尺寸恒定，反向旋转保持正立。
      if (this.selected) {
        Text('🗑')
          .fontSize(13)
          .width(30)
          .height(30)
          .textAlign(TextAlign.Center)
          .backgroundColor('#FF6B6B')
          .borderRadius(15)
          .offset({ x: this.baseSize / 2 - 20, y: -this.baseSize / 2 + 20 })
          .scale({ x: this.badgeScale(), y: this.badgeScale() })
          .rotate({ angle: -this.item.angle })
          .onClick(() => {
            this.onDelete();
          })
      }
    }
    .width(this.baseSize)
    .height(this.baseSize)
    .transform(this.m())
    .onClick(() => {
      this.onSelect(this.item.id);
    })
    // 拖动走默认手势；缩放/旋转走 parallelGesture（并行手势），
    // 保证双指捏合与旋转都能稳定触发，不被默认手势竞争吞掉
    .gesture(
      PanGesture()
        .onActionStart(() => {
          this.onSelect(this.item.id);
          this.basePosX = this.item.posX;
          this.basePosY = this.item.posY;
        })
        .onActionUpdate((e: GestureEvent) => {
          this.item.posX = this.basePosX + e.offsetX;
          this.item.posY = this.basePosY + e.offsetY;
          this.onDirty();
        })
    )
    .parallelGesture(
      PinchGesture({ fingers: 2 })
        .onActionStart(() => {
          this.onSelect(this.item.id);
          this.baseZoom = this.item.zoom;
        })
        .onActionUpdate((e: GestureEvent) => {
          this.item.zoom = Math.min(4, Math.max(0.3, this.baseZoom * e.scale));
          this.onDirty();
        })
    )
    .parallelGesture(
      RotationGesture()
        .onActionStart(() => {
          this.onSelect(this.item.id);
          this.baseAngle = this.item.angle;
        })
        .onActionUpdate((e: GestureEvent) => {
          this.item.angle = this.baseAngle + e.angle;
          this.onDirty();
        })
    )
  }
}

/**
 * StickerBoardPage —— 贴纸画板（自定义背景 + 多贴纸贴图）
 * 背景：相册自选照片 / 内置壁纸；贴纸：底部素材库点击添加
 * 交互：点贴纸选中（虚线框）· 单指拖动 · 双指旋转/缩放 · 点空白取消
 * 导出：SaveButton 安全控件 + componentSnapshot 合成 → 存系统相册
 */
@Component
export struct StickerBoardPage {
  onClose: () => void = () => {};

  /** 多贴纸列表 */
  @State stickers: StickerItem[] = [];
  /** 当前选中 id（-1=无） */
  @State selectedId: number = -1;
  /** 当前内置背景下标（-1=使用自定义背景） */
  @State bgIndex: number = 0;
  /** 自定义背景图（相册选择返回的 uri） */
  @State bgUri: string | undefined = undefined;
  @State saving: boolean = false;
  private nextId: number = 1;
  /**
   * 是否有未保存的画板内容（贴纸增删/拖拽缩放旋转/换背景都会置 true）。
   * 关闭时据此确认，避免返回手势一滑就丢掉摆好的画板；保存成功后复位。
   */
  private dirty: boolean = false;
  /** 返回键处理在 EditGuard 中的注册 id（-1 = 未注册） */
  private backId: number = -1;
  /** 可选内置背景（工程内真实存在） */
  private readonly bgs: string[] = ['default_wallpaper_01', 'default_wallpaper_03', 'default_wallpaper_07'];
  /** 可选贴纸素材（猫猫狗狗插图，工程内真实存在） */
  private readonly library: string[] = [
    'ot035_1', 'ot035_2', 'ot035_3', 'ot035_4', 'ot035_5',
    'ot093', 'ot093_1', 'ot093_2', 'ot093_3', 'ot093_4',
    'ot124', 'ot124_1', 'ot124_2', 'ot124_3', 'ot124_4',
    'ot288', 'ot288_1', 'ot288_2', 'ot288_3',
    'ot304', 'ot304_1', 'ot304_2', 'ot304_3',
    'ot305', 'ot305_1', 'ot305_2', 'ot305_3',
    'ot355', 'ot355_1', 'ot355_2', 'ot355_3',
    'ot372', 'ot372_1', 'ot372_2', 'ot372_3',
    'ot374', 'ot374_1', 'ot374_2', 'ot374_3',
    'ot375', 'ot375_1', 'ot375_2', 'ot375_3',
    'ot396', 'ot396_1', 'ot396_2', 'ot396_3',
    'ot419', 'ot419_1', 'ot419_2', 'ot419_3'
  ];

  private addSticker(name: string): void {
    const list: StickerItem[] = [];
    for (const s of this.stickers) {
      list.push(s);
    }
    // 新贴纸轻微错位，避免完全重叠
    const item: StickerItem = new StickerItem(this.nextId++, name);
    item.posX = 90 + (this.stickers.length % 5) * 18;
    item.posY = 140 + (this.stickers.length % 5) * 18;
    list.push(item);
    this.stickers = list;
    this.selectedId = item.id;
    this.dirty = true;
  }

  private removeSelected(): void {
    if (this.selectedId < 0) {
      promptAction.showToast({ message: '请先点选一张贴纸' });
      return;
    }
    const list: StickerItem[] = [];
    for (const s of this.stickers) {
      if (s.id !== this.selectedId) {
        list.push(s);
      }
    }
    this.stickers = list;
    this.selectedId = -1;
    this.dirty = true;
  }

  /** 当前选中贴纸（无则 undefined） */
  private selectedSticker(): StickerItem | undefined {
    for (const s of this.stickers) {
      if (s.id === this.selectedId) {
        return s;
      }
    }
    return undefined;
  }

  /** 滑杆调选中贴纸大小 */
  private setSelectedZoom(v: number): void {
    const s: StickerItem | undefined = this.selectedSticker();
    if (s !== undefined) {
      s.zoom = v;
      this.dirty = true;
    }
  }

  /** 选中贴纸复位（大小/角度） */
  private resetSelectedTransform(): void {
    const s: StickerItem | undefined = this.selectedSticker();
    if (s !== undefined) {
      s.zoom = 1;
      s.angle = 0;
      this.dirty = true;
    }
  }

  /** 从相册选自定义背景（PhotoViewPicker 系统选择器，无需权限） */
  async pickCustomBg(): Promise<void> {
    try {
      const p: picker.PhotoViewPicker = new picker.PhotoViewPicker();
      const res: picker.PhotoSelectResult = await p.select({
        MIMEType: picker.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      });
      if (res.photoUris.length > 0) {
        this.bgUri = res.photoUris[0];
        this.bgIndex = -1;
        this.selectedId = -1;
        this.dirty = true;
      }
    } catch (e) {
      console.error(`pickCustomBg failed: ${JSON.stringify(e)}`);
    }
  }

  aboutToAppear(): void {
    // 画板是覆盖层：返回键应先问"是否放弃画板"，而不是直接关掉整个页面
    this.backId = EditGuard.push((): boolean => {
      this.requestClose();
      return true;
    });
  }

  aboutToDisappear(): void {
    if (this.backId >= 0) {
      EditGuard.pop(this.backId);
      this.backId = -1;
    }
  }

  /** 请求关闭：画板里有未保存内容时先确认 */
  private async requestClose(): Promise<void> {
    if (!this.dirty) {
      this.onClose();
      return;
    }
    const discard: boolean = await EditGuard.confirmDiscard();
    if (discard) {
      this.onClose();
    }
  }

  /** 保存画板到相册（SaveButton 临时授权 + 组件快照） */
  async saveBoard(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    // 先取消选中，避免删除角标被截进成品图
    this.selectedId = -1;
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    let dest: string = '';
    let snap: image.PixelMap | undefined = undefined;
    let packer: image.ImagePacker | undefined = undefined;
    try {
      await new Promise<void>((resolve) => {
        setTimeout(() => {
          resolve();
        }, 300);
      });
      snap = await componentSnapshot.get('boardRoot');
      packer = image.createImagePacker();
      const buf: ArrayBuffer = await packer.packing(snap, { format: 'image/jpeg', quality: 92 });
      dest = `${ctx.filesDir}/zeroone_board_${Date.now()}.jpg`;
      const f = fileIo.openSync(dest, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      fileIo.writeSync(f.fd, buf);
      fileIo.closeSync(f);
      const phHelper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx);
      const uri: string = await phHelper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'jpg');
      const f2 = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY);
      fileIo.copyFileSync(dest, f2.fd);
      fileIo.closeSync(f2);
      promptAction.showToast({ message: '已保存到相册 📷' });
      // 已导出成功：画板成果已进相册，关闭时无需再提示"放弃"
      this.dirty = false;
    } catch (e) {
      console.error(`saveBoard failed: ${JSON.stringify(e)}`);
      promptAction.showToast({ message: '保存失败，请重试' });
    } finally {
      // 截图与打包器是 Native 资源，必须释放（此前每保存一次泄漏一张全尺寸截图）
      PixelScope.safeRelease(snap);
      if (packer !== undefined) {
        try {
          packer.release();
        } catch (e) {
          console.error(`release packer failed: ${JSON.stringify(e)}`);
        }
      }
      // 拷贝进相册后删除沙箱临时文件（此前这些文件会一直堆在 filesDir 里）
      if (dest.length > 0) {
        try {
          fileIo.unlinkSync(dest);
        } catch (e) {
          // 忽略：文件可能已被清理
        }
      }
      this.saving = false;
    }
  }

  build() {
    Stack() {
      Column() {
        // ===== 顶栏 =====
        Row() {
          Text('‹')
            .fontSize(26).fontColor('#FF6B6B').width(40).height(40).textAlign(TextAlign.Center)
            .onClick(() => {
              // 统一走 requestClose：有未保存内容会先确认
              this.requestClose();
            })
          Text('贴纸画板')
            .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#F2F2F5')
            .layoutWeight(1).textAlign(TextAlign.Center)
          // 保存中在标题位显示进度（此前点保存后无任何反馈，用户容易反复点）
          if (this.saving) {
            Row({ space: 6 }) {
              LoadingProgress().width(14).height(14).color('#FF6B6B')
              Text('保存中…').fontSize(11).fontColor('#9A9AA5')
            }
            .width(80).justifyContent(FlexAlign.End)
          } else {
            Text(`${this.stickers.length} 张贴纸`)
              .fontSize(12).fontColor('#7A7A85').width(80).textAlign(TextAlign.End)
          }
        }
        .width('100%').padding({ top: 10, bottom: 6, left: 8, right: 12 })

        // ===== 背景 + 贴纸层（快照区域） =====
        Stack() {
          if (this.bgUri !== undefined) {
            Image(this.bgUri)
              .width('100%').height('100%').objectFit(ImageFit.Cover)
          } else {
            Image($r(`app.media.${this.bgs[this.bgIndex]}`))
              .width('100%').height('100%').objectFit(ImageFit.Cover)
          }

          ForEach(this.stickers, (s: StickerItem) => {
            StickerNode({
              item: s,
              selected: s.id === this.selectedId,
              onSelect: (id: number) => {
                this.selectedId = id;
              },
              onDirty: () => {
                // 手势拖拽/缩放/旋转也是编辑：接上此前被留空的钩子
                this.dirty = true;
              },
              onDelete: () => {
                this.removeSelected();
              }
            })
          }, (s: StickerItem) => s.id.toString())

        }
        .id('boardRoot')
        .width('100%').layoutWeight(1).backgroundColor('#222222')
        .onClick(() => {
          this.selectedId = -1; // 点空白取消选中
        })

        // ===== 背景选择（相册自定义 + 内置） =====
        Scroll() {
          Row({ space: 8 }) {
            // 相册自定义入口
            Column({ space: 2 }) {
              Text('＋').fontSize(22).fontColor('#FF6B6B')
              Text('相册').fontSize(10).fontColor('#FF6B6B')
            }
            .justifyContent(FlexAlign.Center)
            .width(54).height(72)
            .border({ width: 1.5, color: '#FF6B6B', style: BorderStyle.Dashed })
            .borderRadius(8)
            .onClick(() => {
              this.pickCustomBg();
            })
            ForEach(this.bgs, (b: string, idx: number) => {
              Stack() {
                Image($r(`app.media.${b}`)).width(54).height(72).objectFit(ImageFit.Cover).borderRadius(8)
                if (this.bgIndex === idx) {
                  Column().width(54).height(72).border({ width: 2, color: '#FF6B6B' }).borderRadius(8)
                }
              }
              .onClick(() => {
                this.bgIndex = idx;
                this.bgUri = undefined;
              })
            }, (b: string, idx: number) => idx.toString())
          }
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .backgroundColor('#191A1F')

        // ===== 贴纸素材库 =====
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.library, (n: string) => {
              Image($r(`app.media.${n}`))
                .width(44).height(44).objectFit(ImageFit.Contain)
                .backgroundColor('#2A2B32').borderRadius(10).padding(6)
                .onClick(() => {
                  this.addSticker(n);
                })
            }, (n: string) => n)
          }
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .backgroundColor('#191A1F')

        // ===== 选中贴纸调节行：大小滑杆 + 复位 =====
        if (this.selectedId >= 0) {
          Row({ space: 10 }) {
            Text('🐾 大小')
              .fontSize(12).fontColor('#7A7A85').width(48)
            Slider({
              value: this.selectedSticker() === undefined ? 1 : this.selectedSticker()!.zoom,
              min: 0.3,
              max: 2.5,
              step: 0.05
            })
              .layoutWeight(1)
              .selectedColor('#FF6B6B')
              .onChange((v: number) => {
                this.setSelectedZoom(v);
              })
            Text('↺')
              .fontSize(18).fontColor('#9A9AA5')
              .width(34).height(34).textAlign(TextAlign.Center)
              .backgroundColor('#2A2B32').borderRadius(17)
              .onClick(() => {
                this.resetSelectedTransform();
              })
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 8 })
          .backgroundColor('#0F0F12')
        }

        // ===== 操作行 =====
        Row({ space: 10 }) {
          SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.SAVE_IMAGE, buttonType: ButtonType.Capsule })
            .height(36)
            // 保存中禁用：防止连点产生多张重复相册图
            // （SaveButton 是安全控件，支持属性受限，不能用 opacity 做视觉弱化）
            .enabled(!this.saving)
            .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
              if (result === SaveButtonOnClickResult.SUCCESS) {
                this.saveBoard();
              }
            })
          Text('🗑 删除选中')
            .fontSize(13).fontColor(Color.White).backgroundColor('#FF6B6B')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 }).borderRadius(14)
            .onClick(() => {
              this.removeSelected();
            })
          Text('🧹 清空')
            .fontSize(13).fontColor('#9A9AA5').backgroundColor('#2A2B32')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 }).borderRadius(14)
            .onClick(() => {
              if (this.stickers.length === 0) {
                return;
              }
              this.stickers = [];
              this.selectedId = -1;
              this.dirty = true;
            })
        }
        .width('100%').justifyContent(FlexAlign.Center)
        .padding({ top: 10, bottom: 6 })
        .backgroundColor('#0F0F12')

        Text('点贴纸选中（虚线框）· 单指拖动 / 双指旋转缩放 · 点空白取消')
          .fontSize(11).fontColor('#7A7A85').padding({ bottom: 10 })
          .backgroundColor('#0F0F12')
      }
      .width('100%').height('100%')
    }
    .width('100%').height('100%')
    .backgroundColor('#0F0F12')
  }
}
