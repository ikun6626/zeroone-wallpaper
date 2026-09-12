/**
 * ⚠️ 已废弃 / 无调用方（DEPRECATED）—— 请勿在主干代码中引用
 *
 * 现状：仅被同样废弃的 PhotoEditorPage 使用，而该页面没有任何入口。
 * 替代：图片来源为"本地资源 / 下载到沙箱"，由 ImageEditor.loadOriginal 处理；
 *       导出为原分辨率，由 ImageComposer 离屏合成。
 * 注意：本类的 release(loaded) 约定仍值得沿用 —— PixelMap 必须显式释放。
 * 详见 entry/src/main/ets/DEPRECATED.md
 */

/**
 * ImageRenderer.ets — 图片选择、解码、EXIF 处理、预览图生成
 *
 * 职责：
 * 1. 调用系统相册选择图片
 * 2. 解码为全分辨率 PixelMap（仅用于最终导出）
 * 3. 生成低分辨率预览 PixelMap（用于实时渲染）
 * 4. 读取 EXIF 方向标记
 *
 * 性能约束：
 * - PixelMap 序列化大小上限约 128MiB，超过则不创建全分辨率
 * - 预览图宽度默认 1080px，足够 60fps 渲染
 */

import { image } from '@kit.ImageKit';
import picker from '@ohos.file.picker';

/** PixelMap 序列化大小上限（128 MiB） */
const MAX_PIXELMAP_BYTES: number = 128 * 1024 * 1024;

/** 加载后的图片数据包 */
export interface LoadedImage {
  /** 原始文件 URI */
  sourceUri: string;
  /** 全分辨率 PixelMap（仅用于导出；超大图时为 null，导出时需重新解码） */
  fullPixelMap: image.PixelMap | null;
  /** 预览用低分辨率 PixelMap（用于实时渲染） */
  previewPixelMap: image.PixelMap;
  /** 原图宽度（px） */
  imageWidth: number;
  /** 原图高度（px） */
  imageHeight: number;
  /** EXIF 方向标记 1-8 */
  exifOrientation: number;
}

export class ImageRenderer {
  /**
   * 打开相册选择单张图片并加载
   *
   * @param maxPreviewWidth 预览图最大宽度（px），默认 1080
   * @returns 加载结果；用户取消时返回 null
   */
  static async pickAndLoad(maxPreviewWidth: number = 1080): Promise<LoadedImage | null> {
    // 1. 选择图片
    const uri: string = await ImageRenderer.pickImage();
    if (uri === '') {
      return null; // 用户取消
    }

    // 2. 加载
    return await ImageRenderer.loadFromUri(uri, maxPreviewWidth);
  }

  /**
   * 调用系统相册选择单张图片
   * @returns 选中图片的 URI；用户取消时返回空字符串
   */
  static async pickImage(): Promise<string> {
    const photoPicker = new picker.PhotoViewPicker();
    const result = await photoPicker.select({
      maxSelectNumber: 1
    });
    if (result.photoUris.length === 0) {
      return '';
    }
    return result.photoUris[0];
  }

  /**
   * 从 URI 加载图片，生成全分辨率和预览两个 PixelMap
   *
   * @param uri 图片 URI（file:// 或 datashare://）
   * @param maxPreviewWidth 预览图最大宽度（px）
   */
  static async loadFromUri(uri: string, maxPreviewWidth: number): Promise<LoadedImage> {
    const source: image.ImageSource = image.createImageSource(uri);

    // 1. 读取 EXIF 方向
    let exifOrientation: number = 1;
    try {
      // image.PropertyKey.ORIENTATION = 'Orientation'，SDK 返回 Promise<string>
      const prop: string = await source.getImageProperty(image.PropertyKey.ORIENTATION);
      exifOrientation = parseInt(prop, 10) || 1;
    } catch (e) {
      // 某些图片无 EXIF，默认正向
      exifOrientation = 1;
    }

    // 2. 获取原图尺寸
    const info: image.ImageInfo = await source.getImageInfo();
    const imgW: number = info.size.width;
    const imgH: number = info.size.height;

    // 3. 预览图解码参数（低分辨率）
    const previewW: number = Math.min(maxPreviewWidth, imgW);
    const previewH: number = Math.round(previewW * imgH / imgW);
    const previewOpts: image.DecodingOptions = {
      editable: true,
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      desiredSize: { width: previewW, height: previewH }
    };
    const previewPm: image.PixelMap = await source.createPixelMap(previewOpts);

    // 4. 全分辨率 PixelMap（检查是否超过 128MiB 限制）
    const estimatedBytes: number = imgW * imgH * 4; // RGBA_8888 = 4 bytes/pixel
    let fullPm: image.PixelMap | null = null;
    if (estimatedBytes <= MAX_PIXELMAP_BYTES) {
      const fullOpts: image.DecodingOptions = {
        editable: true,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      };
      fullPm = await source.createPixelMap(fullOpts);
    } else {
      // TODO: 超过 128MiB 限制，导出时需重新解码裁剪区域
      console.warn('ImageRenderer: 原图过大，跳过全分辨率 PixelMap 创建');
    }

    source.release();

    return {
      sourceUri: uri,
      fullPixelMap: fullPm,
      previewPixelMap: previewPm,
      imageWidth: imgW,
      imageHeight: imgH,
      exifOrientation: exifOrientation
    };
  }

  /**
   * 释放 LoadedImage 中的 PixelMap 资源
   * 在页面 aboutToDisappear 时调用
   */
  static release(loaded: LoadedImage): void {
    if (loaded.fullPixelMap !== null) {
      loaded.fullPixelMap.release();
    }
    loaded.previewPixelMap.release();
  }
}
