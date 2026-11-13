import { AuthManager } from '../common/net/AuthManager';
import { EditGuard } from '../common/utils/EditGuard';

/**
 * LoginPage —— 登录页
 *
 * 视觉：青蛙池塘 GIF 全屏动态背景 + 深青渐变遮罩 + 半透明白卡片
 * 配色取自背景青蛙 GIF：水域深青 #264653 / 青绿 #2A9D8F / 浅青 #4ECDC4 / 青蛙暖黄 #E9C46A
 *
 * 交互：账号 + 密码 → 调 AuthManager.login()；成功后登录态广播到 AppStorage，
 * Index 自动切回主界面，本页不需要手动跳转。
 */
@Component
export struct LoginPage {
  /** 点击"去注册"时回调（Index 切到注册页） */
  onGoRegister: () => void = () => {};
  /** 关闭登录页（返回浏览，不强制登录） */
  onClose: () => void = () => {};

  @State username: string = '';
  @State password: string = '';
  @State passwordVisible: boolean = false;
  @State loading: boolean = false;
  @State errorMsg: string = '';

  /** 返回键处理注册 id（-1 = 未注册） */
  private backId: number = -1;

  aboutToAppear(): void {
    // 覆盖层打开期间接管返回键：只关闭本覆盖层，不退出 App、不影响下层页面。
    // 关闭（点 × / 登录成功）即注销；登录成功后的跳转仍由 AuthManager 广播驱动。
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

  // ===== 青蛙池塘配色（取自背景 GIF） =====
  private readonly COLOR_DEEP: string = '#264653';     // 水域深青
  private readonly COLOR_TEAL: string = '#2A9D8F';     // 青绿
  private readonly COLOR_MINT: string = '#4ECDC4';     // 浅青
  private readonly COLOR_GOLD: string = '#E9C46A';     // 青蛙暖黄
  private readonly COLOR_CARD: string = '#CCFFFFFF';   // 半透明白卡片
  private readonly COLOR_INPUT_BG: string = '#66FFFFFF'; // 输入框半透明白

  async doLogin(): Promise<void> {
    const u: string = this.username.trim();
    const p: string = this.password;
    if (u.length === 0) {
      this.errorMsg = '请输入账号';
      return;
    }
    if (p.length === 0) {
      this.errorMsg = '请输入密码';
      return;
    }
    this.errorMsg = '';
    this.loading = true;
    try {
      const resp = await AuthManager.getInstance().login(u, p);
      if (!resp.ok) {
        // 后端约定 401 code=AUTH_FAILED → "用户名或密码错误"
        this.errorMsg = resp.message ?? '登录失败，请重试';
      }
      // 登录成功：AuthManager 已广播 isLoggedIn=true，Index 会自动切走，本页无需操作
    } catch (e) {
      this.errorMsg = '网络异常，请检查网络后重试';
    } finally {
      this.loading = false;
    }
  }

  build() {
    Stack() {
      // 0. 不透明底色：GIF 解码完成前先整屏铺满，
      //    否则下一层的「我的」页文字会透上来，与登录页文案叠成一片
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.COLOR_DEEP)

      // 1. 青蛙 GIF 动态背景（HarmonyOS Image 自动播放 GIF 动画）
      Image($rawfile('frog_bg.gif'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)

      // 2. 深青渐变遮罩：上深下更深，让中段卡片浮起来
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#80001A1A', 0.0], ['#4D264653', 0.45], ['#B3264653', 1.0]]
        })

      // 3. 内容层
      Column({ space: 0 }) {
        // 顶部关闭栏：跳过登录，继续浏览（浏览无需登录）
        Row() {
          Text('跳过')
            .fontSize(14)
            .fontColor('#CC264653')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor('#33FFFFFF')
            .borderRadius(16)
            .onClick(() => { this.onClose(); })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ top: '8%' })

        // 顶部呼吸留白 + 品牌标识
        Column({ space: 8 }) {
          Text('ZeroOne 壁纸')
            .fontSize(20)
            .fontColor('#E9C46A')
            .fontWeight(FontWeight.Medium)
            .letterSpacing(3)
        }
        .width('100%')
        .margin({ top: '10%', bottom: 24 })
        .justifyContent(FlexAlign.Center)

        // 欢迎标题
        Text('欢迎回来')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .width('100%')
          .textAlign(TextAlign.Start)
        Text('登录后即可下载高清壁纸')
          .fontSize(14)
          // 这行落在 GIF 背景上，原来的深青 #CC264653 与背景几乎糊在一起
          // （实测截图里像一层幽灵文字），改为浅色提高对比度
          .fontColor('#CCFFFFFF')
          .margin({ top: 6, bottom: 28 })
          .width('100%')

        // ===== 半透明卡片 =====
        Column({ space: 16 }) {
          // 账号
          Column({ space: 8 }) {
            Text('账号')
              .fontSize(13)
              .fontColor('#264653')
              .fontWeight(FontWeight.Medium)
            TextInput({ text: this.username, placeholder: '请输入账号' })
              .type(InputType.Normal)
              .maxLength(20)
              .height(48)
              .width('100%')
              .backgroundColor(this.COLOR_INPUT_BG)
              .borderRadius(12)
              .border({ width: 1, color: '#33264653' })
              .placeholderColor('#99264653')
              .placeholderFont({ size: 15 })
              .fontColor('#264653')
              .fontSize(15)
              .padding({ left: 14, right: 14 })
              .onChange((v: string) => { this.username = v; this.errorMsg = ''; })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 密码
          Column({ space: 8 }) {
            Text('密码')
              .fontSize(13)
              .fontColor('#264653')
              .fontWeight(FontWeight.Medium)
            Row({ space: 8 }) {
              TextInput({ text: this.password, placeholder: '请输入密码' })
                .type(this.passwordVisible ? InputType.Normal : InputType.Password)
                // 关掉系统自带的密码可见性小眼睛：否则会与本页右侧的显隐按钮
                // 并排出现两个"眼睛"（实测截图里非常突兀）
                .showPasswordIcon(false)
                .maxLength(32)
                .height(48)
                .backgroundColor(this.COLOR_INPUT_BG)
                .borderRadius(12)
                .border({ width: 1, color: '#33264653' })
                .placeholderColor('#99264653')
                .placeholderFont({ size: 15 })
                .fontColor('#264653')
                .fontSize(15)
                .padding({ left: 14, right: 8 })
                .layoutWeight(1)
                .onChange((v: string) => { this.password = v; this.errorMsg = ''; })

              // 显隐切换
              Text(this.passwordVisible ? '🙈' : '👁')
                .fontSize(20)
                .width(40)
                .height(40)
                .textAlign(TextAlign.Center)
                .onClick(() => { this.passwordVisible = !this.passwordVisible; })
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // 错误提示
          if (this.errorMsg.length > 0) {
            Text(this.errorMsg)
              .fontSize(13)
              .fontColor('#C24A32')
              .width('100%')
              .textAlign(TextAlign.Start)
              .margin({ top: 2 })
          }

          // 登录按钮
          Button(this.loading ? '登录中…' : '登录')
            .width('100%')
            .height(50)
            .backgroundColor(this.loading ? '#A6264653' : this.COLOR_DEEP)
            .fontColor('#FFFFFF')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .borderRadius(24)
            .margin({ top: 6 })
            .enabled(!this.loading)
            .onClick(() => { this.doLogin(); })
        }
        .width('100%')
        .padding(22)
        .backgroundColor(this.COLOR_CARD)
        .borderRadius(24)
        .alignItems(HorizontalAlign.Center)

        // 底部：去注册
        Row({ space: 4 }) {
          Text('还没有账号？')
            .fontSize(14)
            .fontColor('#CCFFFFFF')
          Text('立即注册')
            .fontSize(14)
            .fontColor(this.COLOR_GOLD)
            .fontWeight(FontWeight.Bold)
            .onClick(() => { this.onGoRegister(); })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 24 })

        // 占位把内容顶到上半区
        Blank()
      }
      .width('88%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .height('100%')
  }
}
