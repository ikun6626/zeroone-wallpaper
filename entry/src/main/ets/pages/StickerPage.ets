import { StickerStudioPage } from './StickerStudioPage';
import { StickerBoardPage } from './StickerBoardPage';

/**
 * StickerPage —— 贴纸 Tab（宠物贴图主题枢纽）
 *
 * 两个创作入口：
 *  - 🐾 贴纸工作台：选背景 → 贴猫猫狗狗插图 → 手势编辑/阴影调色 → 存相册，或存为锁屏/桌面用图并引导设置
 *  - 🧩 贴纸画板：自定义/内置背景 + 多张贴纸拖拽缩放旋转，保存到相册
 */
@Component
export struct StickerPage {
  /** 是否打开贴纸工作台 */
  @State showStudio: boolean = false;
  /** 是否打开贴纸画板 */
  @State showBoard: boolean = false;

  @Builder
  featureCard(icon: string, circleBg: string, title: string, desc: string, tag: string, action: () => void) {
    Column({ space: 14 }) {
      Row({ space: 14 }) {
        Stack() {
          Circle({ width: 54, height: 54 })
            .fill(circleBg)
          Text(icon)
            .fontSize(26)
        }
        Column({ space: 4 }) {
          Text(title)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F2F2F5')
          Text(desc)
            .fontSize(12)
            .fontColor('#7A7A85')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text('›')
          .fontSize(26)
          .fontColor('#4A4A55')
      }
      .width('100%')

      Row() {
        Text(tag)
          .fontSize(11)
          .fontColor('#FF6B6B')
          .backgroundColor('#3A2530')
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(10)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#1C1D22')
    .borderRadius(18)
    .onClick(() => {
      action();
    })
  }

  build() {
    Stack() {
      Column() {
        // ===== 顶部标题 =====
        Row() {
          Column({ space: 4 }) {
            Text('宠物贴纸')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F2F2F5')
            Text('萌宠插图 · 贴出专属壁纸')
              .fontSize(12)
              .fontColor('#7A7A85')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('🐾')
            .fontSize(30)
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 20, bottom: 16 })

        Scroll() {
          Column({ space: 14 }) {
            this.featureCard('✂️', '#3A2530', '贴纸工作台',
              '选背景 + 贴猫猫狗狗插图，加阴影调色，存好后引导你设为壁纸', '插图拼贴 · 阴影调色 · 设为壁纸引导', () => {
                this.showStudio = true;
              })

            this.featureCard('🧩', '#1F2A36', '贴纸画板',
              '用相册照片或内置背景当底图，贴上萌宠插图自由摆放', '自定义背景 · 多贴纸 · 保存相册', () => {
                this.showBoard = true;
              })

            // ===== 玩法提示 =====
            Column({ space: 8 }) {
              Text('玩法小贴士')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor('#F2F2F5')
                .width('100%')
              Text('1. 工作台先选背景（壁纸库或相册照片），再从底部插图库点选猫猫狗狗贴纸，可重复添加多张\n2. 点贴纸选中后：单指拖动、双指缩放/旋转，也可用「大小」滑杆微调；点空白处可拖动或双指缩放背景\n3. 阴影、调色面板实时预览，选好导出比例后可存 JPG、透明 PNG；点「锁屏图 / 桌面图」会保存到相册并给出图库设置步骤\n4. 画板玩法相同，贴完点保存即存入相册\n5. 说明：受系统限制，三方应用不能直接替换壁纸，需在「图库」里完成最后一步设置')
                .fontSize(12)
                .fontColor('#9A9AA5')
                .lineHeight(20)
                .width('100%')
            }
            .width('100%')
            .padding(16)
            .backgroundColor('#1C1D22')
            .borderRadius(18)
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 24 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#0F0F12')

      // ===== 贴纸工作台（全屏覆盖） =====
      if (this.showStudio) {
        StickerStudioPage({
          onClose: () => {
            this.showStudio = false;
          }
        })
      }

      // ===== 贴纸画板（全屏覆盖） =====
      if (this.showBoard) {
        StickerBoardPage({
          onClose: () => {
            this.showBoard = false;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
