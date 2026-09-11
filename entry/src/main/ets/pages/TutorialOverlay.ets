/**
 * First-launch tutorial using the same visual vocabulary as the real result
 * page: bundled sample content, detection frames and original/copy switching.
 */
@Builder
export function TutorialTile(icon: Resource, size: number, active: boolean = true) {
  Column() {
    SymbolGlyph(icon).fontSize(size * 0.42)
      .fontColor([active ? $r('app.color.on_accent') : $r('app.color.accent')])
  }
  .width(size).height(size).justifyContent(FlexAlign.Center)
  .borderRadius(size * 0.30)
  .backgroundColor(active ? $r('app.color.accent') : $r('app.color.surface'))
  .border({ width: active ? 0 : 1, color: $r('app.color.divider') })
  .scale({ x: active ? 1 : 0.88, y: active ? 1 : 0.88 })
  .animation({ duration: 360, curve: Curve.Friction })
}

@Component
export struct TutorialOverlay {
  onVisibleChange: () => void = () => {};
  @Prop @Watch('onSessionChanged') sessionId: number = 0;
  @State index: number = 0;
  @State introPhase: number = 0;
  @State scanPhase: number = 0;
  @State docPhase: number = 0;
  @State viewportWidth: number = 400;
  @State viewportHeight: number = 640;
  @State contentVisible: boolean = false;
  private swiperController: SwiperController = new SwiperController();
  private total: number = 4;
  private animationGeneration: number = 0;
  aboutToAppear(): void {
    this.resetToFirstPage();
    this.getUIContext().animateTo({ duration: 320, curve: Curve.Friction }, () => {
      this.contentVisible = true;
    });
  }

  aboutToDisappear(): void {
    this.animationGeneration++;
  }

  /** Remaining height for page content (header + footer + sheet chrome). */
  private pageBodyHeight(): number {
    const chrome: number = this.viewportWidth >= 600 ? 180 : 170;
    return Math.max(260, this.viewportHeight - chrome);
  }

  private previewWidth(): number {
    if (this.viewportWidth >= 840) return 200;
    if (this.viewportWidth >= 600) return 180;
    if (this.viewportWidth > this.viewportHeight) {
      return Math.min(140, Math.max(100, this.viewportHeight * 0.32));
    }
    return Math.min(160, Math.max(110, this.viewportWidth * 0.42));
  }

  private schedule(generation: number, delay: number, task: () => void): void {
    setTimeout(() => {
      if (generation === this.animationGeneration) task();
    }, delay);
  }

  private onSessionChanged(): void {
    this.resetToFirstPage();
  }

  private resetToFirstPage(): void {
    this.index = 0;
    this.swiperController.changeIndex(0, false);
    this.playPage(0);
  }

  private playPage(page: number): void {
    const generation: number = ++this.animationGeneration;
    this.introPhase = 0;
    this.scanPhase = 0;
    this.docPhase = 0;
    if (page === 0) {
      this.schedule(generation, 120, () => this.introPhase = 1);
      this.schedule(generation, 430, () => this.introPhase = 2);
      this.schedule(generation, 740, () => this.introPhase = 3);
    } else if (page === 1) {
      this.schedule(generation, 180, () => this.scanPhase = 1);
      this.schedule(generation, 460, () => this.scanPhase = 2);
      this.schedule(generation, 720, () => this.scanPhase = 3);
      this.schedule(generation, 980, () => this.scanPhase = 4);
      this.schedule(generation, 1240, () => this.scanPhase = 5);
      this.schedule(generation, 1500, () => this.scanPhase = 6);
    } else if (page === 2) {
      this.schedule(generation, 220, () => this.docPhase = 1);
      this.schedule(generation, 500, () => this.docPhase = 2);
      this.schedule(generation, 780, () => this.docPhase = 3);
      this.schedule(generation, 1060, () => this.docPhase = 4);
    }
  }

  private goNext(): void {
    const nextPage: number = this.index + 1;
    if (nextPage < this.total) {
      this.swiperController.changeIndex(nextPage, true);
      return;
    }
    this.onVisibleChange();
  }

  @Builder
  PageHeading(title: string) {
    Column({ space: 6 }) {
      Text(title).fontSize(24).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary')).textAlign(TextAlign.Center)
        .width('100%').padding({ left: 10, right: 10 })
      Row().width(36).height(3).borderRadius(2)
        .backgroundColor($r('app.color.accent'))
        .opacity(0.85)
    }.width('100%').alignItems(HorizontalAlign.Center)
  }

  @Builder
  FlowStep(icon: Resource, label: string, phase: number) {
    Column({ space: 8 }) {
      TutorialTile(icon, phase === this.introPhase ? 68 : 58, phase <= this.introPhase)
      Text(label).fontSize(13)
        .fontWeight(phase === this.introPhase ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(phase <= this.introPhase ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
    }
    .opacity(phase <= this.introPhase ? 1 : 0.38)
    .translate({ y: phase <= this.introPhase ? 0 : 8 })
    .animation({ duration: 340, curve: Curve.Friction })
  }

  @Builder
  IntroFlow() {
    Row() {
      this.FlowStep($r('sys.symbol.picture'), '选择', 1)
      Divider().layoutWeight(1).strokeWidth(2)
        .color(this.introPhase >= 2 ? $r('app.color.accent') : $r('app.color.progress_track'))
        .margin({ left: 8, right: 8, bottom: 28 })
      this.FlowStep($r('sys.symbol.eye_viewfinder_slash'), '检查', 2)
      Divider().layoutWeight(1).strokeWidth(2)
        .color(this.introPhase >= 3 ? $r('app.color.accent') : $r('app.color.progress_track'))
        .margin({ left: 8, right: 8, bottom: 28 })
      this.FlowStep($r('sys.symbol.checkmark_shield'), '副本', 3)
    }.width('100%').justifyContent(FlexAlign.Center).padding({ left: 8, right: 8 })
  }

  @Builder
  DetectionBadge(text: string, color: ResourceColor, phase: number) {
    Text(text).fontSize(11).fontWeight(FontWeight.Medium).fontColor(Color.White)
      .padding({ left: 9, right: 9, top: 5, bottom: 5 })
      .borderRadius(13).backgroundColor(color)
      .opacity(this.scanPhase >= phase ? 1 : 0)
      .scale({ x: this.scanPhase >= phase ? 1 : 0.72, y: this.scanPhase >= phase ? 1 : 0.72 })
      .animation({ duration: 320, curve: Curve.Friction })
  }

  @Builder
  PhotoPreview() {
    Stack() {
      Image($rawfile('tutorial_destroy_base.jpg'))
        .width('100%').height('100%').objectFit(ImageFit.Cover).borderRadius(22)
      Column().width('46%').height('50%').position({ x: '30%', y: '27%' })
          .border({ width: 2.5, color: '#F6C344' }).borderRadius(8)
          .opacity(this.scanPhase >= 5 ? 1 : 0)
          .scale({ x: this.scanPhase >= 5 ? 1 : 0.82, y: this.scanPhase >= 5 ? 1 : 0.82 })
          .animation({ duration: 340, curve: Curve.Friction })
      Column().width('26%').height('21%').position({ x: '4%', y: '4%' })
          .border({ width: 2.5, color: '#E05A2B' }).borderRadius(7)
          .opacity(this.scanPhase >= 6 ? 1 : 0)
          .scale({ x: this.scanPhase >= 6 ? 1 : 0.82, y: this.scanPhase >= 6 ? 1 : 0.82 })
          .animation({ duration: 340, curve: Curve.Friction })
      Row({ space: 6 }) {
        this.DetectionBadge('人脸', '#A87900', 5)
        this.DetectionBadge('二维码', '#C94B22', 6)
      }.position({ x: '8%', y: '87%' })
      if (this.scanPhase >= 1) {
        Divider().width('92%').strokeWidth(2).color($r('app.color.accent'))
          .position({ x: '4%', y: this.scanPhase >= 5 ? '86%' : '12%' })
          .shadow({ radius: 8, color: $r('app.color.accent') })
          .animation({ duration: 900, curve: Curve.EaseInOut })
      }
    }
    .width(this.previewWidth()).aspectRatio(0.8).borderRadius(22).clip(true)
    .shadow({ radius: 16, color: $r('app.color.shadow'), offsetY: 5 })
    .accessibilityGroup(true)
    .accessibilityText('样例照片扫描预览')
  }

  @Builder
  ScanResultCard(icon: Resource, title: string, detail: string, phase: number) {
    Row({ space: 8 }) {
      SymbolGlyph(icon).fontSize(17).fontColor([$r('app.color.accent')])
      Column({ space: 1 }) {
        Text(title).fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Text(detail).fontSize(10).fontColor($r('app.color.text_tertiary')).maxLines(1)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }
    .layoutWeight(1).height(54).padding({ left: 10, right: 8 })
    .borderRadius(14).backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.divider') })
    .opacity(this.scanPhase >= phase ? 1 : 0.22)
    .translate({ y: this.scanPhase >= phase ? 0 : 8 })
      .animation({ duration: 340, curve: Curve.Friction })
  }

  @Builder
  DocumentPreview() {
    Row({ space: 14 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        Column({ space: 7 }) {
          Text('PROJECT').fontSize(8).fontWeight(FontWeight.Bold).fontColor('#263238')
          Divider().width(45).strokeWidth(2).color('#166E5B')
          Text('HANDOVER').fontSize(10).fontWeight(FontWeight.Medium).fontColor('#263238')
          Divider().width(38).color('#D8DDDB')
          Divider().width(46).color('#D8DDDB')
          Divider().width(32).color('#D8DDDB')
        }.alignItems(HorizontalAlign.Start).padding({ left: 10, top: 13 })
        Text('W').fontSize(10).fontWeight(FontWeight.Bold).fontColor(Color.White)
          .width(22).height(22).textAlign(TextAlign.Center).backgroundColor('#2B579A')
          .position({ x: 48, y: 66 })
      }
      .width(72).height(94).borderRadius(6).backgroundColor('#FFFFFF')
      .border({ width: 1, color: '#E3E7E5' })
      .shadow({ radius: 8, color: $r('app.color.shadow'), offsetY: 3 })

      Column({ space: 5 }) {
        Text('Harbor_Handover.docx').fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text('37 KB · Microsoft Word').fontSize(12).fontColor($r('app.color.text_tertiary'))
        Row({ space: 5 }) {
          SymbolGlyph(this.docPhase >= 4 ? $r('sys.symbol.checkmark_circle_fill') :
            $r('sys.symbol.doc_text')).fontSize(16).fontColor([$r('app.color.accent')])
          Text(this.docPhase >= 4 ? '已生成干净副本' : '检出 10 项可清理属性')
            .fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.accent'))
        }.margin({ top: 5 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 })
  }

  @Builder
  DocPropRow(label: string, value: string, phase: number) {
    Row({ space: 10 }) {
      Text(label).fontSize(13).fontColor($r('app.color.text_tertiary')).width(76)
      Stack({ alignContent: Alignment.Start }) {
        Text(value).fontSize(14).fontColor($r('app.color.text_primary'))
          .opacity(this.docPhase >= phase ? 0 : 1).translate({ x: this.docPhase >= phase ? -8 : 0 })
          .animation({ duration: 260, curve: Curve.EaseOut })
        Text('已清除').fontSize(13).fontColor($r('app.color.accent'))
          .padding({ left: 10, right: 10, top: 3, bottom: 3 })
          .borderRadius(10).backgroundColor($r('app.color.accent_soft'))
          .opacity(this.docPhase >= phase ? 1 : 0).translate({ x: this.docPhase >= phase ? 0 : 8 })
          .animation({ duration: 300, curve: Curve.Friction })
      }.layoutWeight(1)
    }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  FinalStep(icon: Resource, num: string, title: string, detail: string) {
    Row({ space: 14 }) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width(48).height(48).borderRadius(16).backgroundColor($r('app.color.accent_soft'))
        SymbolGlyph(icon).fontSize(22).fontColor([$r('app.color.accent')])
        Text(num).fontSize(10).fontWeight(FontWeight.Bold).fontColor($r('app.color.on_accent'))
          .width(18).height(18).textAlign(TextAlign.Center).borderRadius(9)
          .backgroundColor($r('app.color.accent')).position({ x: 34, y: -4 })
      }.width(48).height(48)
      Column({ space: 3 }) {
        Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Text(detail).fontSize(12).fontColor($r('app.color.text_tertiary'))
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.width('100%').padding(16).borderRadius(18)
      .backgroundColor($r('app.color.surface'))
      .border({ width: 1, color: $r('app.color.surface_outline') })
      .shadow({ radius: 10, color: $r('app.color.shadow'), offsetY: 4 })
  }

  @Builder
  MiniCard() {
    Column().width('100%').padding(14).borderRadius(16)
      .backgroundColor($r('app.color.surface'))
      .border({ width: 1.5, color: $r('app.color.surface_outline') })
  }

  /** Thumbnail that matches the real full-bleed preview chrome. */
  @Builder
  MiniPreviewImage() {
    Stack() {
      Image($rawfile('tutorial_destroy_base.jpg'))
        .width('100%').height('100%').objectFit(ImageFit.Cover)
      Row({ space: 5 }) {
        this.DetectionBadge('人脸', '#A87900', this.scanPhase >= 5 ? 6 : 0)
        this.DetectionBadge('二维码', '#C94B22', this.scanPhase >= 6 ? 6 : 0)
      }.position({ x: 10, y: this.previewHeightGuess() - 34 })
      Column().width('46%').height('50%').position({ x: '30%', y: '27%' })
        .border({ width: 2, color: '#F6C344' }).borderRadius(8)
        .opacity(this.scanPhase >= 5 ? 1 : 0)
        .animation({ duration: 340, curve: Curve.Friction })
      Column().width('26%').height('21%').position({ x: '4%', y: '4%' })
        .border({ width: 2, color: '#E05A2B' }).borderRadius(7)
        .opacity(this.scanPhase >= 6 ? 1 : 0)
        .animation({ duration: 340, curve: Curve.Friction })
    }
    .width(this.previewWidth()).height(Math.min(220, Math.round(this.previewWidth() * 1.05)))
    .borderRadius(16).clip(true)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1.5, color: $r('app.color.surface_outline') })
  }

  private previewHeightGuess(): number {
    return Math.round(this.previewWidth() * 1.15);
  }

  @Builder
  MiniSummaryCard(count: number) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text('检查完成').fontSize(12).fontColor($r('app.color.text_secondary'))
        Text(`${count} 项`).fontSize(26).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.accent'))
      }.alignItems(HorizontalAlign.Start)
      Text('1 个文件已完成检查').fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1).textAlign(TextAlign.End)
    }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 10 })
      .borderRadius(16).backgroundColor($r('app.color.surface'))
      .border({ width: 1.5, color: $r('app.color.surface_outline') })
  }

  @Builder
  MiniMetaHeader() {
    Row({ space: 12 }) {
      Text('元数据风险').fontSize(14).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Text('收起').fontSize(12).fontColor($r('app.color.accent'))
    }.width('100%').padding(12)
      .borderRadius(16).backgroundColor($r('app.color.surface'))
      .border({ width: 1.5, color: $r('app.color.surface_outline') })
  }

  private isClearedPhase(phase: number): boolean {
    return this.scanPhase >= phase || this.docPhase >= phase;
  }

  @Builder
  MiniMetaRow(title: string, value: string, phase: number) {
    Row({ space: 10 }) {
      Column() {
        Text('•').fontSize(15).fontWeight(FontWeight.Bold).fontColor($r('app.color.accent'))
      }.width(28).height(28).justifyContent(FlexAlign.Center)
        .borderRadius(14).backgroundColor($r('app.color.accent_soft'))
      Column({ space: 2 }) {
        Text(title).fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Stack({ alignContent: Alignment.Start }) {
          Text(value).fontSize(11).fontColor($r('app.color.text_secondary')).maxLines(1)
            .opacity(this.isClearedPhase(phase) ? 0 : 1)
            .translate({ x: this.isClearedPhase(phase) ? -28 : 0 })
            .animation({ duration: 280, curve: Curve.EaseOut })
            .visibility(this.isClearedPhase(phase) ? Visibility.None : Visibility.Visible)
          Text('已清除').fontSize(10).fontColor($r('app.color.accent'))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(8).backgroundColor($r('app.color.accent_soft'))
            .opacity(this.isClearedPhase(phase) ? 1 : 0)
            .translate({ x: this.isClearedPhase(phase) ? 0 : 28 })
            .animation({ duration: 300, curve: Curve.Friction })
        }.width('100%').height(20)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text(this.isClearedPhase(phase) ? '已删除' : '删除')
        .fontSize(11).fontColor($r('app.color.warning'))
    }.width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .opacity(this.isClearedPhase(phase) ? 1 : 0.7)
      .animation({ duration: 300, curve: Curve.Friction })
  }

  @Builder
  TutorialPages() {
    Swiper(this.swiperController) {
      Column({ space: 28 }) {
        this.PageHeading('分享前，多一道安心')
        this.IntroFlow()
      }.width('100%').height('100%').justifyContent(FlexAlign.Center)
        .padding({ left: 20, right: 20, bottom: 34 })

      Column({ space: 10 }) {
        this.PageHeading('看见照片里藏着什么')
        Scroll() {
          Column({ space: 10 }) {
            this.MiniPreviewImage()
            this.MiniSummaryCard(6)
            this.MiniMetaHeader()
            Column({ space: 0 }) {
              this.MiniMetaRow('包含精确拍摄位置', '深圳市 · GPS 坐标', 1)
              Divider().color($r('app.color.divider'))
              this.MiniMetaRow('包含拍摄时间', '08/01 17:30', 2)
              Divider().color($r('app.color.divider'))
              this.MiniMetaRow('包含拍摄设备', '品牌 · 型号 · 镜头', 3)
              Divider().color($r('app.color.divider'))
              this.MiniMetaRow('包含摄影参数', '光圈 · ISO · 曝光', 4)
              Divider().color($r('app.color.divider'))
              this.MiniMetaRow('包含署名信息', '作者 · 版权 · 软件', 5)
              Divider().color($r('app.color.divider'))
              this.MiniMetaRow('视觉隐私区域', '人脸 1 · 二维码 1', 6)
            }.width('100%').borderRadius(16).backgroundColor($r('app.color.surface'))
              .border({ width: 1.5, color: $r('app.color.surface_outline') })
          }.width('100%')
        }
        .constraintSize({ minHeight: 0, maxHeight: this.pageBodyHeight() - 48 })
        .layoutWeight(1).width('100%')
        .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.None)
      }.width('100%').height('100%').padding({ left: 18, right: 18, bottom: 24 })

      Column({ space: 10 }) {
        this.PageHeading('文件里也藏着身份信息')
        Scroll() {
          Column({ space: 10 }) {
            Row({ space: 10 }) {
              Column() {
                SymbolGlyph($r('sys.symbol.doc_text')).fontSize(18)
                  .fontColor([$r('app.color.on_accent')])
              }.width(36).height(36).justifyContent(FlexAlign.Center)
                .borderRadius(12).backgroundColor($r('app.color.accent'))
              Column({ space: 2 }) {
                Text('Harbor_Handover.docx').fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text('Word 文档 · 1 个文件').fontSize(11).fontColor($r('app.color.text_tertiary'))
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }.width('100%').padding(12).borderRadius(16)
              .backgroundColor($r('app.color.accent_soft'))
            this.MiniMetaHeader()
            Column({ space: 0 }) {
              this.MiniMetaRow('包含文档作者', 'Jia Ning Chen', 1)
              Divider().color($r('app.color.divider'))
              this.MiniMetaRow('包含最后修改者', 'Mingyuan Zhou', 2)
              Divider().color($r('app.color.divider'))
              this.MiniMetaRow('包含公司', 'Yuanlan Digital Technology', 3)
              Divider().color($r('app.color.divider'))
              this.MiniMetaRow('包含文档关键词', 'wayfinding; delivery; acceptance', 4)
            }.width('100%').borderRadius(16).backgroundColor($r('app.color.surface'))
              .border({ width: 1.5, color: $r('app.color.surface_outline') })
            Row({ space: 8 }) {
              SymbolGlyph(this.docPhase >= 4 ? $r('sys.symbol.checkmark_circle_fill') :
                $r('sys.symbol.doc_text')).fontSize(15).fontColor([$r('app.color.accent')])
              Text(this.docPhase >= 4 ? '已生成干净副本' : '检出 10 项可清理属性')
                .fontSize(12).fontWeight(FontWeight.Medium).fontColor($r('app.color.accent'))
            }.padding({ top: 2 })
          }.width('100%')
        }
        .constraintSize({ minHeight: 0, maxHeight: this.pageBodyHeight() - 48 })
        .layoutWeight(1).width('100%')
        .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.None)
      }.width('100%').height('100%').padding({ left: 18, right: 18, bottom: 24 })

      Column({ space: 22 }) {
        this.PageHeading('三步，安全分享')
        Column({ space: 12 }) {
          this.FinalStep($r('sys.symbol.picture'), '1', '选择内容', '照片、文档或支持的媒体文件')
          this.FinalStep($r('sys.symbol.eye_viewfinder_slash'), '2', '确认处理', '逐项删除、保留或替换元数据')
          this.FinalStep($r('sys.symbol.paperplane'), '3', '分享副本', '分享结束后自动清理临时文件')
        }.width(Math.min(480, this.viewportWidth - 48))
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.checkmark_shield_fill')).fontSize(18).fontColor([$r('app.color.accent')])
          Text('处理仅在本机完成').fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary'))
        }.padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(99).backgroundColor($r('app.color.accent_soft'))
      }.width('100%').height('100%').justifyContent(FlexAlign.Center)
        .padding({ left: 20, right: 20, bottom: 34 })
    }
    .index(this.index).loop(false).width('100%')
    .constraintSize({ minHeight: 0, maxHeight: this.pageBodyHeight() })
    .layoutWeight(1)
    .indicator(new DotIndicator().itemWidth(7).itemHeight(7)
      .selectedItemWidth(20).selectedItemHeight(7)
      .color($r('app.color.progress_track')).selectedColor($r('app.color.accent')))
    .indicatorInteractive(true).duration(420).curve(Curve.Friction)
    .onChange((page: number) => {
      this.index = page;
      this.playPage(page);
    })
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('快速上手').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(`${this.index + 1} / ${this.total}`).fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
        Blank()
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(17)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40).height(40)
        .backgroundColor($r('app.color.material_surface'))
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN)
        .border({ width: 1, color: $r('app.color.surface_outline') })
        .accessibilityText('关闭教程')
        .onClick(() => this.onVisibleChange())
      }.width('100%').padding({ left: 6, right: 6, bottom: 8 })

      this.TutorialPages()

      Row({ space: 12 }) {
        if (this.index > 0) {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(21)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(48).height(48)
          .backgroundColor($r('app.color.material_surface'))
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN)
          .border({ width: 1, color: $r('app.color.surface_outline') })
          .accessibilityText('上一步')
          .onClick(() => this.swiperController.changeIndex(this.index - 1, true))
        } else {
          Column().width(48).height(48)
        }
        Button(this.index >= this.total - 1 ? '开始使用' : '下一步',
          { type: ButtonType.Capsule })
          .layoutWeight(1).height(48).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_accent')).backgroundColor($r('app.color.accent'))
          .accessibilityText(this.index >= this.total - 1 ? '完成教程并开始使用' :
            `下一步，第 ${this.index + 2} 页`)
          .onClick(() => this.goNext())
        Column().width(48).height(48)
      }.width('100%').padding({ left: 4, right: 4, top: 10 })
    }
    .width('100%').height('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 12 })
    .backgroundColor($r('app.color.page_background'))
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
    .opacity(this.contentVisible ? 1 : 0)
    .scale({ x: this.contentVisible ? 1 : 0.98, y: this.contentVisible ? 1 : 0.98 })
    .animation({ duration: 320, curve: Curve.Friction })
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const width: number = Math.round(Number.parseFloat(newValue.width.toString()));
      const height: number = Math.round(Number.parseFloat(newValue.height.toString()));
      if (Number.isFinite(width) && width > 0) this.viewportWidth = width;
      if (Number.isFinite(height) && height > 0) this.viewportHeight = height;
    })
  }
}
