import { Wallpaper } from '../model/Wallpaper';
import { WallpaperApi, WallpaperPage } from '../common/net/WallpaperApi';
import { ApiResponse } from '../common/net/HttpClient';
import { PreferenceUtil } from '../common/utils/PreferenceUtil';
import { RemoteImage } from '../common/components/RemoteImage';
import { CardStatsOverlay } from '../common/components/CardStatsOverlay';
import { ImagePreview } from '../common/components/ImagePreview';
import { Haptics } from '../common/utils/Haptics';
import { EditGuard } from '../common/utils/EditGuard';

/**
 * SearchPage —— 独立搜索页（2026-11-07）
 *
 * 入口：首页搜索胶囊 → 本页（不再直接跳到图库）。
 * 结构：返回 + 自动聚焦输入框 + 清除；
 *   - 未搜索：搜索历史（最多 10，可单条删除 / 清空需二次确认）+ 热门搜索 + 猜你想搜；
 *   - 输入中：debounce 300ms 的即时建议；
 *   - 已搜索：命中数 + 排序（相关度 / 最新 / 最热）+ 双列结果 + 空结果兜底推荐词。
 *
 * 数据：
 *  - 搜索走服务端 `GET /wallpapers?keyword=`（后端已覆盖标题/tags/类目，实测
 *    「什锦治愈」552 条、「猫咪」2 条）；
 *  - 历史/热门只来自本机搜索记录（本版没有服务端热搜统计，文档已标注局限）；
 *  - 相关度排序：服务端结果上按「标签精确命中 > 标题包含 > 其余」稳定重排（仅当前已加载页）。
 */
@Component
export struct SearchPage {
  onClose: () => void = () => {};

  @State query: string = '';
  @State submitted: boolean = false;
  @State results: Wallpaper[] = [];
  @State total: number = 0;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State hasMore: boolean = false;
  @State sortMode: string = 'rel';
  @State history: string[] = [];
  @State suggestions: string[] = [];
  @State showSuggest: boolean = false;
  @State note: string = '';
  @State previewItem: Wallpaper | undefined = undefined;

  private page: number = 1;
  private seq: number = 0;
  private suggestTimer: number = -1;
  /** 返回键处理在 EditGuard 中的注册 id（-1 = 未注册） */
  private backId: number = -1;

  /** 无历史时的兜底热词（真实类目/常用词，不造假热度） */
  private defaults: string[] = ['动漫插画', '自然风景', '城市建筑', '动物萌宠',
    '文字壁纸', '情侣', '星空', '插画', '雪山', '夜景', '天空', '山川', '森林', '海边'];

  private historyKey: string = 'search_history_v1';

  aboutToAppear(): void {
    this.loadHistory();
    // 返回键：本页是盖在 Tabs 之上的独立页，必须自己接管，否则按返回会直接退出 App。
    // 页内预览（ImagePreview）在本页之后注册，位于栈顶，会优先关预览；
    // 预览关闭后再按返回才走到这里 → 关闭搜索页回到原 Tab，层级不跳。
    this.backId = EditGuard.push((): boolean => {
      this.onClose();
      return true;
    });
    setTimeout((): void => {
      focusControl.requestFocus('searchInput');
    }, 120);
  }

  aboutToDisappear(): void {
    if (this.backId >= 0) {
      EditGuard.pop(this.backId);
      this.backId = -1;
    }
  }

  private loadHistory(): void {
    const raw: string = PreferenceUtil.getString(this.historyKey, '');
    if (raw.length === 0) {
      this.history = [];
      return;
    }
    try {
      const arr: string[] = JSON.parse(raw) as string[];
      this.history = Array.isArray(arr) ? arr.slice(0, 10) : [];
    } catch (e) {
      this.history = [];
    }
  }

  private saveHistory(): void {
    PreferenceUtil.setString(this.historyKey, JSON.stringify(this.history));
  }

  /** 记录一次搜索：去重、最新在前、最多 10 条 */
  private pushHistory(kw: string): void {
    const k: string = kw.trim();
    if (k.length === 0) {
      return;
    }
    const next: string[] = [k];
    for (let i = 0; i < this.history.length && next.length < 10; i++) {
      if (this.history[i] !== k) {
        next.push(this.history[i]);
      }
    }
    this.history = next;
    this.saveHistory();
  }

  private removeHistory(kw: string): void {
    this.history = this.history.filter((x: string): boolean => x !== kw);
    this.saveHistory();
  }

  private clearHistory(): void {
    AlertDialog.show({
      title: '清空搜索历史',
      message: '确定要清空全部搜索记录吗？',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: '#E5484D',
        action: (): void => {
          this.history = [];
          this.saveHistory();
        }
      }
    });
  }

  /** 输入变化：debounce 300ms 出建议 */
  private onChangeQuery(v: string): void {
    // doSearch 会程序化改写 TextInput 的 text，可能回调到这里；
    // 已进入结果态且值一致时忽略，避免把 submitted 又打回 false。
    if (this.submitted && v === this.query) {
      return;
    }
    this.query = v;
    this.submitted = false;
    this.showSuggest = v.trim().length > 0;
    if (this.suggestTimer >= 0) {
      clearTimeout(this.suggestTimer);
      this.suggestTimer = -1;
    }
    this.suggestTimer = setTimeout((): void => {
      this.suggestTimer = -1;
      this.buildSuggestions();
    }, 300);
  }

  private buildSuggestions(): void {
    const k: string = this.query.trim().toLowerCase();
    if (k.length === 0) {
      this.suggestions = [];
      return;
    }
    const out: string[] = [];
    const push = (w: string): void => {
      if (w.length > 0 && out.indexOf(w) === -1 && w.toLowerCase().indexOf(k) >= 0) {
        out.push(w);
      }
    };
    for (let i = 0; i < this.history.length; i++) {
      push(this.history[i]);
    }
    for (let i = 0; i < this.defaults.length; i++) {
      push(this.defaults[i]);
    }
    this.suggestions = out.slice(0, 6);
  }

  private hotWords(): string[] {
    if (this.history.length > 0) {
      return this.history.slice(0, 8);
    }
    return this.defaults.slice(0, 8);
  }

  private doSearch(kw: string): void {
    const k: string = kw.trim();
    if (k.length === 0) {
      return;
    }
    this.submitted = true;
    this.showSuggest = false;
    this.suggestions = [];
    this.query = k;
    this.pushHistory(k);
    this.note = '';
    this.page = 1;
    this.results = [];
    this.total = 0;
    this.hasMore = false;
    this.loadPage();
  }

  private sortParam(): string {
    // 服务端无 relevance 参数：相关度沿用默认 newest，客户端再做标签/标题重排
    if (this.sortMode === 'hot') {
      return 'hot';
    }
    return 'latest';
  }

  private loadPage(): void {
    if (this.loading || this.loadingMore) {
      return;
    }
    const isFirst: boolean = this.page === 1;
    if (isFirst) {
      this.loading = true;
    } else {
      this.loadingMore = true;
    }
    this.seq = this.seq + 1;
    const mySeq: number = this.seq;
    const kw: string = this.query.trim();
    WallpaperApi.fetchPage(this.page, 30, -1, this.sortParam(), kw).then((resp: ApiResponse<WallpaperPage>): void => {
      if (mySeq !== this.seq) {
        return;
      }
      this.loading = false;
      this.loadingMore = false;
      if (!resp.ok || resp.data === undefined) {
        this.note = '网络异常，请稍后重试';
        this.hasMore = false;
        return;
      }
      this.total = resp.data.total;
      this.hasMore = resp.data.hasMore;
      const incoming: Wallpaper[] = resp.data.items;
      if (isFirst) {
        this.results = this.rank(incoming, kw);
      } else {
        this.results = this.mergeUnique(this.results, this.rank(incoming, kw));
      }
      if (this.results.length === 0) {
        this.note = '';
      }
    }).catch((): void => {
      if (mySeq !== this.seq) {
        return;
      }
      this.loading = false;
      this.loadingMore = false;
      this.note = '网络异常，请稍后重试';
    });
  }

  private loadMore(): void {
    if (!this.hasMore || this.loading || this.loadingMore) {
      return;
    }
    this.page = this.page + 1;
    this.loadPage();
  }

  /** 相关度重排：标签精确命中 > 标题包含 > 其余（保持原相对顺序） */
  private rank(items: Wallpaper[], kw: string): Wallpaper[] {
    const k: string = kw.trim().toLowerCase();
    if (this.sortMode !== 'rel' || k.length === 0) {
      return items;
    }
    const exact: Wallpaper[] = [];
    const title: Wallpaper[] = [];
    const rest: Wallpaper[] = [];
    for (let i = 0; i < items.length; i++) {
      const w: Wallpaper = items[i];
      const tags: string[] = w.tagList;
      let tagHit: boolean = false;
      for (let j = 0; j < tags.length; j++) {
        if (tags[j].toLowerCase() === k) {
          tagHit = true;
          break;
        }
      }
      if (tagHit) {
        exact.push(w);
      } else if (w.title.toLowerCase().indexOf(k) >= 0) {
        title.push(w);
      } else {
        rest.push(w);
      }
    }
    return exact.concat(title).concat(rest);
  }

  private mergeUnique(base: Wallpaper[], incoming: Wallpaper[]): Wallpaper[] {
    const out: Wallpaper[] = base.slice();
    for (let i = 0; i < incoming.length; i++) {
      const w: Wallpaper = incoming[i];
      if (out.findIndex((x: Wallpaper): boolean => x.id === w.id) === -1) {
        out.push(w);
      }
    }
    return out;
  }

  private toggleFavorite(w: Wallpaper, fav: boolean): void {
    // 按目标状态写入（不做盲 toggle），避免爱心回显延迟时连点造成反向操作
    PreferenceUtil.setFavoriteItem(w.id, w, fav);
  }

  private fmtCount(n: number): string {
    if (n >= 10000) {
      return `${Math.round(n / 1000) / 10}W`;
    }
    if (n >= 1000) {
      return `${Math.round(n / 100) / 10}K`;
    }
    return String(n);
  }

  private ratioOf(w: Wallpaper): number {
    if (w.width > 0 && w.height > 0) {
      return w.width / w.height;
    }
    return 0.72;
  }

  @Builder
  chip(text: string, picked: boolean, onTap: () => void) {
    Text(text)
      .fontSize(12)
      .fontColor(picked ? '#FFFFFF' : '#A8A8B5')
      .backgroundColor(picked ? '#C9333D' : '#1C1D22')
      .height(32)
      .padding({ left: 12, right: 12 })
      .borderRadius(16)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .onClick((): void => {
        Haptics.light();
        onTap();
      })
  }

  @Builder
  resultCard(w: Wallpaper) {
    Stack() {
      RemoteImage({
        url: w.thumbUrl.length > 0 ? w.thumbUrl : w.imageUrl,
        fit: ImageFit.Cover
      })
        .width('100%')
        .height('100%')
      CardStatsOverlay({
        w: w,
        onFavorite: (item: Wallpaper, fav: boolean): void => {
          this.toggleFavorite(item, fav);
        }
      })
    }
    .width('100%')
    .aspectRatio(this.ratioOf(w))
    .borderRadius(12)
    .clip(true)
    .backgroundColor('#1A1A1A')
    .onClick((): void => {
      this.previewItem = w;
    })
  }

  build() {
    Stack() {
      Column() {
        // 顶栏：返回 + 输入框 + 清除
        Row({ space: 8 }) {
          Text('‹')
            .fontSize(30)
            .fontColor('#EDEDF2')
            .width(40)
            .height(44)
            .textAlign(TextAlign.Center)
            .onClick((): void => {
              this.onClose();
            })
          Row() {
            Text('🔍')
              .fontSize(12)
              .margin({ left: 12, right: 6 })
            TextInput({ text: this.query, placeholder: '搜索壁纸 / 合辑 / 标签' })
              .id('searchInput')
              .fontSize(13)
              .fontColor('#EDEDF2')
              .placeholderColor('#6F6F7A')
              .backgroundColor('#00000000')
              .layoutWeight(1)
              .height(40)
              .caretColor('#C9333D')
              .enterKeyType(EnterKeyType.Search)
              .onChange((v: string): void => {
                this.onChangeQuery(v);
              })
              .onSubmit((): void => {
                this.doSearch(this.query);
              })
            if (this.query.length > 0) {
              Text('×')
                .fontSize(16)
                .fontColor('#9B9CA8')
                .width(32)
                .height(40)
                .textAlign(TextAlign.Center)
                .onClick((): void => {
                  this.query = '';
                  this.submitted = false;
                  this.showSuggest = false;
                  this.results = [];
                  this.total = 0;
                  this.note = '';
                })
            }
          }
          .layoutWeight(1)
          .height(40)
          .backgroundColor('#1C1D22')
          .borderRadius(20)
        }
        .width('100%')
        .padding({ left: 8, right: 12, top: 6, bottom: 6 })

        if (!this.submitted) {
          // 未搜索：历史 / 热门 / 猜你想搜
          Scroll() {
            Column({ space: 14 }) {
              if (this.showSuggest && this.suggestions.length > 0) {
                Column() {
                  ForEach(this.suggestions, (s: string) => {
                    Row() {
                      Text('🔍').fontSize(12).margin({ right: 8 })
                      Text(s).fontSize(13).fontColor('#EDEDF2').layoutWeight(1)
                    }
                    .width('100%')
                    .height(40)
                    .padding({ left: 14, right: 14 })
                    .onClick((): void => {
                      this.doSearch(s);
                    })
                  }, (s: string) => `sug_${s}`)
                }
                .width('100%')
                .backgroundColor('#17181D')
                .borderRadius(12)
              }

              if (this.history.length > 0) {
                Column({ space: 8 }) {
                  Row() {
                    Text('搜索历史').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#EDEDF2')
                    Blank()
                    Text('清空')
                      .fontSize(11)
                      .fontColor('#9B9CA8')
                      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                      .onClick((): void => {
                        this.clearHistory();
                      })
                  }
                  .width('100%')
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach(this.history, (h: string) => {
                      Row() {
                        Text(h)
                          .fontSize(12)
                          .fontColor('#D9D9E0')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(' ×')
                          .fontSize(12)
                          .fontColor('#6F6F7A')
                          .onClick((): void => {
                            this.removeHistory(h);
                          })
                      }
                      .height(32)
                      .padding({ left: 10, right: 6 })
                      .margin({ right: 8, bottom: 8 })
                      .backgroundColor('#1C1D22')
                      .borderRadius(16)
                      .onClick((): void => {
                        this.doSearch(h);
                      })
                    }, (h: string) => `his_${h}`)
                  }
                }
                .width('100%')
              }

              Column({ space: 8 }) {
                Text('热门搜索').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#EDEDF2')
                  .width('100%')
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.hotWords(), (h: string) => {
                    this.chip(h, false, (): void => {
                      this.doSearch(h);
                    })
                  }, (h: string) => `hot_${h}`)
                }
                .width('100%')
              }
              .width('100%')

              Column({ space: 8 }) {
                Text('猜你想搜').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#EDEDF2')
                  .width('100%')
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.defaults.slice(0, 3), (h: string) => {
                    this.chip(h, false, (): void => {
                      this.doSearch(h);
                    })
                  }, (h: string) => `guess_${h}`)
                }
                .width('100%')
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 8 })
            .justifyContent(FlexAlign.Start)
          }
          .scrollBar(BarState.Off)
          .align(Alignment.Top)
          .layoutWeight(1)
        } else {
          // 结果区：命中数 + 排序 + 双列
          Row({ space: 8 }) {
            Text(`共 ${this.fmtCount(this.total)} 张`)
              .fontSize(12)
              .fontColor('#9B9CA8')
            Blank()
            this.chip('相关度', this.sortMode === 'rel', (): void => {
              this.sortMode = 'rel';
              this.doSearch(this.query);
            })
            this.chip('最新', this.sortMode === 'latest', (): void => {
              this.sortMode = 'latest';
              this.doSearch(this.query);
            })
            this.chip('最热', this.sortMode === 'hot', (): void => {
              this.sortMode = 'hot';
              this.doSearch(this.query);
            })
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 4, bottom: 8 })

          if (this.loading && this.results.length === 0) {
            Column() {
              LoadingProgress().width(36).height(36).color('#C9333D')
              Text('搜索中…').fontSize(12).fontColor('#9B9CA8').margin({ top: 8 })
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else if (!this.loading && this.results.length === 0) {
            Column({ space: 10 }) {
              Text('没找到相关壁纸').fontSize(16).fontColor('#EDEDF2')
              Text(this.note.length > 0 ? this.note : '换个词试试：')
                .fontSize(12)
                .fontColor('#9B9CA8')
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.defaults.slice(0, 3), (h: string) => {
                  this.chip(h, false, (): void => {
                    this.doSearch(h);
                  })
                }, (h: string) => `empty_${h}`)
              }
            }
            .width('100%')
            .layoutWeight(1)
            .padding({ left: 14, right: 14, top: 60 })
          } else {
            WaterFlow() {
              ForEach(this.results, (w: Wallpaper) => {
                FlowItem() {
                  this.resultCard(w)
                }
              }, (w: Wallpaper) => `sr_${w.id}`)
            }
            .columnsTemplate('1fr 1fr')
            .columnsGap(8)
            .rowsGap(8)
            .padding({ left: 12, right: 12, bottom: 20 })
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .onReachEnd((): void => {
              this.loadMore();
            })
          }
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#111114')

      if (this.previewItem !== undefined) {
        ImagePreview({
          wallpaper: this.previewItem,
          neighbor: (_: Wallpaper, __: number): Wallpaper | undefined => undefined,
          onClose: (): void => {
            this.previewItem = undefined;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#111114')
  }
}
