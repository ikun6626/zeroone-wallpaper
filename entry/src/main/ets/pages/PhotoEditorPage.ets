/**
 * ⚠️ 已废弃 / 无入口（DEPRECATED）—— 请勿挂到任何入口
 *
 * 现状：main_pages.json 只注册了 pages/Index，本页从未被任何页面引用；
 *       且仍是 Phase-1 骨架（"取消"是空实现、"完成"只 toast "导出功能待实现"）。
 * 替代：全屏预览 → ImageEditor（旋转/裁剪/滤镜/纹理/文字/贴纸/导出）已完整上线。
 * 处理建议：确认不再需要后，连同 common/photoeditor/* 一并删除。
 * 详见 entry/src/main/ets/DEPRECATED.md
 */

/**
 * PhotoEditorPage.ets — 照片编辑器主页面（Phase 1：骨架 + 图片选择 + 预览）
 *
 * 交互流程：
 * 1. 点击"选择图片" → 系统相册
 * 2. 加载预览 PixelMap + 全分辨率 PixelMap
 * 3. 显示预览图 + 图片信息
 * 4. 后续阶段在此基础上叠加裁剪框、手势、工具栏
 */

import { image } from '@kit.ImageKit';
import { promptAction } from '@kit.ArkUI';
import { EditState, EditStateFactory } from '../common/photoeditor/model/EditState';
import { ImageRenderer, LoadedImage } from '../common/photoeditor/service/ImageRenderer';

@Component
export struct PhotoEditorPage {
  /** 加载后的图片数据（非 @State，避免 PixelMap 被代理） */
  private loaded: LoadedImage | null = null;

  /** UI 状态：是否有图片 */
  @State hasImage: boolean = false;
  /** 预览 PixelMap（@State 驱动 Image 组件刷新） */
  @State previewPixelMap: image.PixelMap | null = null;
  /** 原图宽度 */
  @State imgWidth: number = 0;
  /** 原图高度 */
  @State imgHeight: number = 0;
  /** EXIF 方向 */
  @State exifOrientation: number = 1;
  /** 加载中 */
  @State isLoading: boolean = false;

  /** 编辑状态（后续阶段使用） */
  private editState: EditState | null = null;

  /** 预览区尺寸（onAreaChange 更新） */
  private viewWidth: number = 360;
  private viewHeight: number = 640;

  aboutToDisappear(): void {
    if (this.loaded !== null) {
      ImageRenderer.release(this.loaded);
      this.loaded = null;
    }
  }

  /**
   * 选择并加载图片
   */
  private async pickImage(): Promise<void> {
    this.isLoading = true;
    try {
      const result: LoadedImage | null = await ImageRenderer.pickAndLoad(1080);
      if (result === null) {
        // 用户取消
        return;
      }

      // 释放旧图
      if (this.loaded !== null) {
        ImageRenderer.release(this.loaded);
      }

      this.loaded = result;
      this.previewPixelMap = result.previewPixelMap;
      this.imgWidth = result.imageWidth;
      this.imgHeight = result.imageHeight;
      this.exifOrientation = result.exifOrientation;
      this.hasImage = true;

      // 初始化编辑状态
      this.editState = EditStateFactory.createDefault(
        this.viewWidth, this.viewHeight,
        result.imageWidth, result.imageHeight
      );

      promptAction.showToast({
        message: `加载成功 ${result.imageWidth}×${result.imageHeight}`,
        duration: 1500
      });
    } catch (e) {
      promptAction.showToast({
        message: `加载失败: ${(e as Error).message}`,
        duration: 2000
      });
    } finally {
      this.isLoading = false;
    }
  }

  build(): void {
    Column() {
      // ===== 顶部导航栏 =====
      Row() {
        Text('取消')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .onClick(() => {
            // TODO: 退出页面/关闭弹窗
          })

        Blank()

        Text('照片编辑')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')

        Blank()

        Text('完成')
          .fontSize(16)
          .fontColor(this.hasImage ? '#007AFF' : '#555555')
          .onClick(() => {
            // TODO Phase 6: 导出全分辨率 + 壁纸设置
            if (this.hasImage) {
              promptAction.showToast({ message: '导出功能待实现' });
            }
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .backgroundColor('#1C1C1E')

      // ===== 编辑区 =====
      Stack() {
        if (this.hasImage && this.previewPixelMap !== null) {
          // 预览图（Contain 适配）
          Image(this.previewPixelMap)
            .objectFit(ImageFit.Contain)
            .width('100%')
            .height('100%')

          // TODO Phase 2: 裁剪框 + 暗色遮罩 + 三分网格线
          // TODO Phase 3: 图片平移/缩放/旋转手势
          // TODO Phase 4: 比例选择 + 旋转/镜像按钮
        } else {
          // 空状态
          Column({ space: 16 }) {
            Image($r('sys.media.ohos_ic_public_add'))
              .width(48)
              .height(48)
              .fillColor('#666666')

            Text('点击选择图片')
              .fontSize(16)
              .fontColor('#666666')

            Button('从相册选择')
              .type(ButtonType.Capsule)
              .fontSize(14)
              .width(140)
              .height(40)
              .backgroundColor('#007AFF')
              .fontColor('#FFFFFF')
              .enabled(!this.isLoading)
              .onClick(() => {
                this.pickImage();
              })
          }
          .justifyContent(FlexAlign.Center)
        }

        // 加载中遮罩
        if (this.isLoading) {
          Column({ space: 12 }) {
            LoadingProgress()
              .width(40)
              .height(40)
              .color('#007AFF')
            Text('加载中...')
              .fontSize(14)
              .fontColor('#999999')
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .height('100%')
          .backgroundColor('#80000000')
        }
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor('#000000')
      .onAreaChange((_old: Area, newArea: Area) => {
        this.viewWidth = newArea.width;
        this.viewHeight = newArea.height;
        // 尺寸变化时重新初始化编辑状态
        if (this.loaded !== null && this.editState !== null) {
          this.editState = EditStateFactory.createDefault(
            this.viewWidth, this.viewHeight,
            this.loaded.imageWidth, this.loaded.imageHeight
          );
        }
      })

      // ===== 底部信息栏（Phase 1 临时） =====
      if (this.hasImage) {
        Row({ space: 16 }) {
          Text(`原图 ${this.imgWidth}×${this.imgHeight}`)
            .fontSize(12)
            .fontColor('#999999')
          Text(`EXIF ${this.exifOrientation}`)
            .fontSize(12)
            .fontColor('#999999')
          Blank()
          Text('重置')
            .fontSize(14)
            .fontColor('#007AFF')
            .onClick(() => {
              // TODO Phase 4: 重置编辑状态
              if (this.loaded !== null) {
                this.editState = EditStateFactory.createDefault(
                  this.viewWidth, this.viewHeight,
                  this.loaded.imageWidth, this.loaded.imageHeight
                );
                promptAction.showToast({ message: '已重置' });
              }
            })
        }
        .width('100%')
        .height(48)
        .padding({ left: 16, right: 16 })
        .backgroundColor('#1C1C1E')
      }

      // TODO Phase 2: 底部工具栏（裁剪/旋转/比例/镜像/取消/完成）
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
