import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { EditGuard } from '../utils/EditGuard';

/**
 * SetWallpaperGuide —— “设为壁纸”公共引导能力（唯一真相源）
 *
 * 背景（重要，别再把这里改回“一键设为壁纸”）：
 *  - @ohos.wallpaper 自 API 9 起废弃，HarmonyOS NEXT 不向三方应用开放直接换壁纸的能力；
 *  - 因此诚实且可用的闭环只有一条：SaveButton 安全控件授权 → 保存到系统相册 →
 *    引导用户在「图库」里设为锁屏/桌面壁纸。
 *
 * 本文件把这条闭环的**文案 + 弹窗 + 页内引导卡片**集中在这里，
 * 首页大图预览（ImagePreview）、贴纸专区（StickerPage）以及后续任何
 * 导出路径统一调用，避免各写一份导致文案漂移（此前“一键设为壁纸”的虚假承诺
 * 就是各写一份造成的）。
 */

/** 壁纸目标：锁屏 / 桌面 */
export enum WallpaperKind {
  LOCK = 0,
  HOME = 1
}

/** 目标中文名，供所有文案拼接使用 */
export function wallpaperKindName(kind: number): string {
  return kind === WallpaperKind.LOCK ? '锁屏' : '桌面';
}

/**
 * 图库设置步骤（多行纯文本）
 * 弹窗、页内卡片、剪贴板复制共用同一份文本，改一处即全局生效。
 */
export function setWallpaperSteps(kind: number): string {
  return `1. 打开「图库」App\n`
    + `2. 找到刚保存的这张图\n`
    + `3. 点右下角「更多」→「设为壁纸」\n`
    + `4. 选择「${wallpaperKindName(kind)}壁纸」即可`;
}

/** 一行式提示，用于 toase / 卡片副标题 */
export function setWallpaperHint(kind: number): string {
  return `已保存到相册，请到「图库」将其设为${wallpaperKindName(kind)}壁纸`;
}

/** 复制步骤到剪贴板（与 MinePage 反馈邮箱同一套 API，已验证可用） */
export function copySetWallpaperSteps(kind: number): void {
  const text: string = `设为${wallpaperKindName(kind)}壁纸：\n${setWallpaperSteps(kind)}`;
  const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
  // 用户切到图库后还能照着看，避免“看完就忘”
  pasteboard.getSystemPasteboard().setData(data).then(() => {
    promptAction.showToast({ message: '步骤已复制，切到「图库」照着做即可' });
  }).catch(() => {
    promptAction.showToast({ message: '复制失败，请按提示手动操作' });
  });
}

/**
 * 引导弹窗（适合“点完即走”的场景，如贴纸工作台）
 *
 * 使用约束：必须在 SaveButton 的 onClick 回调**返回之后**再调用，
 * 安全控件的授权回调内不要做耗时或弹窗操作，否则容易被系统截断。
 */
export async function showSetWallpaperDialog(kind: number): Promise<void> {
  const name: string = wallpaperKindName(kind);
  const res: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
    title: `${name}壁纸图已保存到相册`,
    message: `设置${name}壁纸步骤：\n${setWallpaperSteps(kind)}`,
    buttons: [
      { text: '复制步骤', color: '#A8A8B5' },
      { text: '我知道了', color: '#C9333D' }
    ]
  });
  // index 0 = 复制步骤
  if (res.index === 0) {
    copySetWallpaperSteps(kind);
  }
}

/**
 * 页内引导卡片（全屏遮罩 + 底部卡片）
 *
 * 为什么预览页用卡片而不是系统弹窗：预览页是沉浸式大图，
 * 系统弹窗会打断浏览；卡片可停留、可复制步骤、可自行关闭。
 */
@Component
export struct SetWallpaperGuidePanel {
  /** 目标：WallpaperKind.LOCK / WallpaperKind.HOME */
  @Prop kind: number = 0;
  /**
   * 卡片里当前选中的目标（默认取 kind，可在卡片内切换）
   *
   * 为什么要在卡片里切换：写相册必须走 SaveButton 的临时授权，
   * 点按钮前再问"锁屏还是桌面"容易超时；保存后在同一张卡片里选是 Cuto 的做法。
   */
  @State activeKind: number = 0;
  onClose: () => void = () => {};
  /** 返回键处理在 EditGuard 中的注册 id（-1 = 未注册） */
  private backId: number = -1;

  aboutToAppear(): void {
    this.activeKind = this.kind;
    // 引导卡片叠在预览之上：返回键应先关卡片，而不是把预览一起关掉
    this.backId = EditGuard.push((): boolean => {
      this.onClose();
      return true;
    });
  }

  aboutToDisappear(): void {
    if (this.backId >= 0) {
      EditGuard.pop(this.backId);
      this.backId = -1;
    }
  }

  /** 目标选择胶囊：锁屏 / 桌面（选中态用与预览页一致的金色） */
  @Builder
  kindChip(label: string, kind: number) {
    Text(label)
      .fontSize(13)
      .fontColor(this.activeKind === kind ? '#111114' : '#C9C9D1')
      .backgroundColor(this.activeKind === kind ? '#E6C07E' : '#26272E')
      .padding({ left: 18, right: 18, top: 7, bottom: 7 })
      .borderRadius(16)
      .onClick(() => {
        this.activeKind = kind;
      })
  }

  build() {
    Stack() {
      // 遮罩：点击关闭；同时吃掉穿透到预览图的手势，
      // 否则点一下引导层会连带触发“单击切换工具栏显隐”
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .onClick(() => {
          this.onClose();
        })

      // 底部卡片
      Column({ space: 12 }) {
        Row({ space: 8 }) {
          Text('✅').fontSize(18)
          Text('已保存到系统相册')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F2F2F5')
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor('#A8A8B5')
            .width(28)
            .height(28)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.onClose();
            })
        }
        .width('100%')

        Text(`设为${wallpaperKindName(this.activeKind)}壁纸`)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F2F2F5')
          .width('100%')

        // 锁屏 / 桌面切换：保存后的目标在这里选（Cuto 同款交互）
        Row({ space: 10 }) {
          this.kindChip('锁屏', WallpaperKind.LOCK)
          this.kindChip('桌面', WallpaperKind.HOME)
        }
        .width('100%')

        Text(setWallpaperSteps(this.activeKind))
          .fontSize(13)
          .fontColor('#A8A8B5')
          .lineHeight(22)
          .width('100%')

        Row({ space: 10 }) {
          Button('复制步骤')
            .fontSize(13)
            .fontColor('#F2F2F5')
            .backgroundColor('#26272E')
            .height(40)
            .layoutWeight(1)
            .onClick(() => {
              copySetWallpaperSteps(this.activeKind);
            })
          Button('我知道了')
            .fontSize(13)
            .fontColor(Color.White)
            .backgroundColor('#C9333D')
            .height(40)
            .layoutWeight(1)
            .onClick(() => {
              this.onClose();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding(18)
      .backgroundColor('#1C1D22')
      .borderRadius({ topLeft: 20, topRight: 20 })
      .position({ x: 0, y: '100%' })
      .markAnchor({ x: 0, y: '100%' })
    }
    .width('100%')
    .height('100%')
  }
}
