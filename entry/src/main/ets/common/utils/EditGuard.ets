import { promptAction } from '@kit.ArkUI';

/** 返回键处理项（用 id 标识，避免依赖函数引用比较） */
interface BackHandlerRef {
  id: number;
  handler: () => boolean;
}

/**
 * EditGuard —— 编辑态保护：返回键拦截 + 未保存修改确认
 *
 * 解决两类高频差评（交互审计 M2）：
 *  1. **创作成果意外丢失**：编辑器/预览/引导层有大量未保存状态（旋转、裁剪、滤镜、
 *     纹理、文字），此前系统返回手势一滑即全部丢失，且返回键会直接把 App 退出。
 *  2. **覆盖层层级错乱**：首页大图预览、图片编辑器、设为壁纸引导
 *     都是叠在同一个 @Entry 页面上的覆盖层，系统返回键必须由"最上层"来处理。
 *     （贴纸专区已合并为「贴纸」Tab 页本身，不再是覆盖层。）
 *
 * 用法：
 *   // 覆盖层 aboutToAppear
 *   this.backId = EditGuard.push((): boolean => { this.requestClose(); return true; });
 *   // 覆盖层 aboutToDisappear
 *   if (this.backId >= 0) { EditGuard.pop(this.backId); this.backId = -1; }
 *   // @Entry 页面
 *   onBackPress(): boolean { return EditGuard.handleBack(); }
 *
 * 约定：处理函数返回 true = 已消费（不再走系统默认行为，例如退出应用）。
 */
export class EditGuard {
  /** 处理栈：后注册的覆盖层在上层，优先处理返回键 */
  private static handlers: BackHandlerRef[] = [];
  /** 自增 id（不用函数引用比较，规避 ArkTS 对函数相等判断的限制） */
  private static nextId: number = 1;

  /** 注册覆盖层返回键处理，返回注销用的 id */
  static push(handler: () => boolean): number {
    const id: number = EditGuard.nextId;
    EditGuard.nextId = id + 1;
    const ref: BackHandlerRef = { id: id, handler: handler };
    EditGuard.handlers.push(ref);
    return id;
  }

  /** 注销（覆盖层销毁时调用） */
  static pop(id: number): void {
    for (let i = 0; i < EditGuard.handlers.length; i++) {
      if (EditGuard.handlers[i].id === id) {
        EditGuard.handlers.splice(i, 1);
        return;
      }
    }
  }

  /**
   * 交给最上层覆盖层处理
   * @returns true = 已消费；false = 无覆盖层，交给系统默认行为
   */
  static handleBack(): boolean {
    const n: number = EditGuard.handlers.length;
    if (n === 0) {
      return false;
    }
    const top: BackHandlerRef = EditGuard.handlers[n - 1];
    return top.handler();
  }

  /** 当前是否有覆盖层（调试用） */
  static depth(): number {
    return EditGuard.handlers.length;
  }

  /**
   * 放弃编辑确认弹窗
   * @returns true = 用户确认放弃（可以关闭）
   *
   * 失败时保守返回 false（不关闭）：宁可让用户多点一次，
   * 也不能因为弹窗异常就把未保存的创作直接丢掉。
   */
  static async confirmDiscard(): Promise<boolean> {
    try {
      const res: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
        title: '放弃编辑？',
        message: '你的修改还没有保存，返回后将丢失。',
        buttons: [
          { text: '继续编辑', color: '#A8A8B5' },
          { text: '放弃', color: '#C9333D' }
        ]
      });
      return res.index === 1;
    } catch (e) {
      console.error(`EditGuard confirmDiscard failed: ${JSON.stringify(e)}`);
      return false;
    }
  }
}
