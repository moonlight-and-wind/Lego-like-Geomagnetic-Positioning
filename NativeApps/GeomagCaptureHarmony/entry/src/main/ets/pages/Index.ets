import { common } from '@kit.AbilityKit';
import { CaptureConfig, CaptureSnapshot, RoutePoint } from '../model/CaptureModels';
import { CapturePackageExporter, ExportResult } from '../service/CapturePackageExporter';
import { MotionRecorder } from '../service/MotionRecorder';
import { RoutePlanner } from '../service/RoutePlanner';

@Entry
@Component
struct Index {
  private recorder: MotionRecorder = new MotionRecorder();
  private refreshTimer: number = -1;
  private lastSnapshot?: CaptureSnapshot;
  private exportResult?: ExportResult;

  @State roomMappingMode: boolean = true;
  @State scanRouteMode: string = 'single';
  @State reverseRouteMode: boolean = false;
  @State datasetName: string = 'room_map_1';
  @State coordinateFrame: string = 'room-1';
  @State roomWidth: string = '6.0';
  @State roomLength: string = '8.0';
  @State lineSpacing: string = '0.5';
  @State supplementSpacing: string = '1.0';
  @State startX: string = '0.0';
  @State startY: string = '0.0';
  @State initialHeading: string = '0.0';
  @State freeRouteText: string = '';
  @State manualAnchorX: string = '0.0';
  @State manualAnchorY: string = '0.0';

  @State isRecording: boolean = false;
  @State isPaused: boolean = false;
  @State isBusy: boolean = false;
  @State hasExportPackage: boolean = false;
  @State statusMessage: string = '准备采集';
  @State errorMessage: string = '';
  @State elapsedText: string = '0.0 s';
  @State sensorCountText: string = '加速度 0 · 陀螺仪 0 · 磁场 0 · 姿态 0';
  @State attitudeText: string = '横滚 0.0° · 俯仰 0.0° · 航向 0.0°';
  @State magneticText: string = '0.0 µT';
  @State routeProgress: string = '尚未开始';
  @State routePhase: string = '横向蛇形';
  @State nextRoutePoint: string = '';
  @State packageStatus: string = '尚无可导出采集包';

  aboutToDisappear(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
    if (this.recorder.isRecording) {
      this.lastSnapshot = this.recorder.stop('page-disappear');
      this.buildPackage();
    }
  }

  private requiredNumber(value: string): number {
    let trimmed = value.trim();
    return trimmed.length === 0 ? Number.NaN : Number(trimmed);
  }

  private startCapture(): void {
    this.errorMessage = '';
    let width = this.requiredNumber(this.roomWidth);
    let length = this.requiredNumber(this.roomLength);
    let spacing = this.requiredNumber(this.scanRouteMode === 'long_cross'
      ? this.supplementSpacing : this.lineSpacing);
    let x = this.requiredNumber(this.startX);
    let y = this.requiredNumber(this.startY);
    let requestedHeading = this.requiredNumber(this.initialHeading);
    if (this.datasetName.trim().length === 0 || this.coordinateFrame.trim().length === 0) {
      this.errorMessage = '请填写数据集名称和房间坐标系名称。';
      return;
    }
    if (!Number.isFinite(x) || !Number.isFinite(y)) {
      this.errorMessage = '起点坐标必须是有效数字。';
      return;
    }
    let minimumSpacing = this.scanRouteMode === 'long_cross' ? 0.5 : 0.2;
    let maximumSpacing = this.scanRouteMode === 'long_cross' ? 2.0 : 1.0;
    if (this.roomMappingMode && (!Number.isFinite(width) || !Number.isFinite(length) ||
      !Number.isFinite(spacing) || width <= 0 || length <= 0 ||
      spacing < minimumSpacing || spacing > maximumSpacing)) {
      this.errorMessage = this.scanRouteMode === 'long_cross'
        ? '可扫描区域的长、宽必须大于 0，横穿间距应为 0.5～2.0 m。'
        : '可扫描区域的长、宽必须大于 0，线距应为 0.2～1.0 m。';
      return;
    }

    let route = this.plannedRoute();
    if (!this.roomMappingMode && this.freeRouteText.trim().length > 0 && route.length === 0) {
      this.errorMessage = '真实路线格式错误。请使用 x,y; x,y，并至少填写两个点。';
      return;
    }
    let routeIssue = route.length > 0 ? RoutePlanner.routeIssue(route) : '';
    if (routeIssue.length > 0) {
      this.errorMessage = routeIssue;
      return;
    }
    if (route.length === 0 && !Number.isFinite(requestedHeading)) {
      this.errorMessage = '未填写真实路线时，初始航向必须是有效数字。';
      return;
    }
    if (!this.roomMappingMode && route.length > 0 && !this.reverseRouteMode) {
      let distance = Math.sqrt((route[0].x - x) * (route[0].x - x) + (route[0].y - y) * (route[0].y - y));
      if (distance > 0.25) {
        this.errorMessage = '真实路线第一个坐标必须与起点一致（允许 0.25 m 误差）。';
        return;
      }
    }
    let effectiveStartX = route.length > 0 ? route[0].x : x;
    let effectiveStartY = route.length > 0 ? route[0].y : y;
    let effectiveHeading = route.length > 0
      ? RoutePlanner.initialHeadingDegrees(route, 0) : requestedHeading;
    let config = new CaptureConfig();
    config.datasetKey = this.datasetName.trim();
    config.coordinateFrame = this.coordinateFrame.trim();
    config.startX = effectiveStartX;
    config.startY = effectiveStartY;
    config.initialHeadingDegrees = effectiveHeading;
    config.routeDirection = this.reverseRouteMode && route.length > 0 ? 'reverse' : 'forward';
    config.sampleRateHz = 100;
    config.route = route;
    this.recorder.start(config);
    if (!this.recorder.isRecording) {
      this.errorMessage = this.recorder.statusMessage;
      this.packageStatus = '传感器启动失败，未开始采集';
      this.refreshViewState();
      return;
    }
    this.exportResult = undefined;
    this.hasExportPackage = false;
    this.lastSnapshot = undefined;
    this.packageStatus = '采集中，停止后生成兼容采集包';
    this.startRefreshTimer();
    this.refreshViewState();
  }

  private stopCapture(): void {
    if (!this.isRecording) {
      return;
    }
    if (this.recorder.nextRouteIndex < this.currentRoutePointCount()) {
      AlertDialog.show({
        title: '路线尚未完成',
        message: '仍有扫描点未确认。可以继续采集，也可以保留当前数据并停止。',
        primaryButton: {
          value: '继续采集',
          action: () => {}
        },
        secondaryButton: {
          value: '停止并保存',
          fontColor: '#C42B1C',
          action: () => { this.finalizeCapture(); }
        }
      });
    } else {
      this.finalizeCapture();
    }
  }

  private finalizeCapture(): void {
    this.lastSnapshot = this.recorder.stop('user-stop');
    this.refreshViewState();
    this.buildPackage();
  }

  private async buildPackage(): Promise<void> {
    if (!this.lastSnapshot) {
      return;
    }
    this.isBusy = true;
    this.packageStatus = '正在生成采集包…';
    try {
      let context = getContext(this) as common.UIAbilityContext;
      this.exportResult = await CapturePackageExporter.build(context, this.lastSnapshot);
      this.hasExportPackage = true;
      this.packageStatus = `已安全保存：${this.exportResult.archiveName}`;
    } catch (error) {
      this.hasExportPackage = false;
      this.errorMessage = `生成采集包失败：${String(error)}`;
      this.packageStatus = '采集数据仍保留在应用内';
    }
    this.isBusy = false;
  }

  private async exportPackage(): Promise<void> {
    if (!this.exportResult) {
      return;
    }
    this.isBusy = true;
    try {
      let context = getContext(this) as common.UIAbilityContext;
      await CapturePackageExporter.saveArchive(context, this.exportResult);
      this.packageStatus = `导出成功：${this.exportResult.archiveName}`;
    } catch (error) {
      let message = String(error);
      if (!message.includes('cancel')) {
        this.errorMessage = `导出失败：${message}`;
      }
    }
    this.isBusy = false;
  }

  private startRefreshTimer(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
    }
    this.refreshTimer = setInterval(() => {
      this.refreshViewState();
    }, 250);
  }

  private refreshViewState(): void {
    this.isRecording = this.recorder.isRecording;
    this.isPaused = this.recorder.isPaused;
    this.statusMessage = this.recorder.statusMessage;
    this.elapsedText = `${this.recorder.elapsedSeconds.toFixed(1)} s`;
    this.sensorCountText = `加速度 ${this.recorder.counts.accelerometer} · 陀螺仪 ${this.recorder.counts.gyroscope}` +
      ` · 磁场 ${this.recorder.counts.magnetometer} · 姿态 ${this.recorder.counts.deviceMotion}`;
    this.attitudeText = `横滚 ${this.recorder.rollDegrees.toFixed(1)}° · 俯仰 ${this.recorder.pitchDegrees.toFixed(1)}°` +
      ` · 航向 ${this.recorder.globalHeadingDegrees.toFixed(1)}°`;
    this.magneticText = `${this.recorder.magneticMagnitude.toFixed(1)} µT`;
    this.routeProgress = this.recorder.routeProgressText();
    this.routePhase = this.recorder.routePhaseText();
    this.nextRoutePoint = this.recorder.nextRoutePointText();
    if (!this.recorder.isRecording && this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  private currentRoutePointCount(): number {
    return this.recorder.snapshot().config.route.length;
  }

  private plannedRoutePointCount(): number {
    return this.plannedRoute().length;
  }

  private plannedRoute(): RoutePoint[] {
    if (!this.roomMappingMode) {
      let freeRoute = RoutePlanner.parse(this.freeRouteText);
      return this.reverseRouteMode ? RoutePlanner.reversed(freeRoute) : freeRoute;
    }
    let width = this.requiredNumber(this.roomWidth);
    let length = this.requiredNumber(this.roomLength);
    let spacing = this.requiredNumber(this.scanRouteMode === 'long_cross'
      ? this.supplementSpacing : this.lineSpacing);
    if (!Number.isFinite(width) || !Number.isFinite(length) || !Number.isFinite(spacing) ||
      width <= 0 || length <= 0) {
      return [];
    }
    let originX = this.requiredNumber(this.startX);
    let originY = this.requiredNumber(this.startY);
    if (!Number.isFinite(originX) || !Number.isFinite(originY)) {
      return [];
    }
    let route = this.scanRouteMode === 'long_cross'
      ? RoutePlanner.longSideCrossing(width, length, spacing, originX, originY)
      : RoutePlanner.serpentine(width, length, spacing, originX, originY, this.scanRouteMode === 'cross');
    return this.reverseRouteMode ? RoutePlanner.reversed(route) : route;
  }

  private plannedRouteSummary(): string {
    let route = this.plannedRoute();
    if (route.length === 0) {
      return '请先填写有效的扫描区域参数。';
    }
    let first = route[0];
    let last = route[route.length - 1];
    let heading = RoutePlanner.initialHeadingDegrees(route, 0);
    return `实际起点 (${first.x.toFixed(2)}, ${first.y.toFixed(2)}) · ` +
      `终点 (${last.x.toFixed(2)}, ${last.y.toFixed(2)}) · 初始航向 ${heading.toFixed(0)}°`;
  }

  private freeRouteStatus(): string {
    if (this.freeRouteText.trim().length === 0) {
      return '可选；填写后会逐点引导，并用于 macOS 显示真实路线。';
    }
    let route = this.plannedRoute();
    if (route.length === 0) {
      return '格式错误：请使用 x,y; x,y。';
    }
    let issue = RoutePlanner.routeIssue(route);
    return issue.length > 0 ? issue : this.plannedRouteSummary();
  }

  private plannedInitialHeadingText(): string {
    return RoutePlanner.initialHeadingDegrees(this.plannedRoute(), 0).toFixed(1);
  }

  private showObstacleGuide(): void {
    AlertDialog.show({
      title: '遇到障碍物时',
      message: '1. 在障碍物前的已知点记录锚点。\n' +
        '2. 点击暂停，再绕过桌子或沙发；如果目标点本身不可达，才点击“跳过此点”。\n' +
        '3. 到障碍物另一侧已知坐标后点击恢复，并立即记录锚点。\n' +
        '4. 沿障碍物可通行边界补扫；家具内部保留为不可定位区域。',
      confirm: { value: '知道了', action: () => {} }
    });
  }

  private recordManualAnchor(): void {
    let x = this.requiredNumber(this.manualAnchorX);
    let y = this.requiredNumber(this.manualAnchorY);
    if (!Number.isFinite(x) || !Number.isFinite(y)) {
      this.errorMessage = '手动锚点坐标必须是有效数字。';
      return;
    }
    this.recorder.recordManualAnchor(x, y);
    this.refreshViewState();
  }

  @Builder
  private sectionTitle(title: string, subtitle: string) {
    Column({ space: 3 }) {
      Text(title).fontSize(19).fontWeight(FontWeight.Bold).fontColor('#172033')
      Text(subtitle).fontSize(13).fontColor('#667085')
    }.alignItems(HorizontalAlign.Start).width('100%')
  }

  @Builder
  private labeledInput(label: string, value: string, onChanged: (value: string) => void,
    inputType: InputType = InputType.Normal, enabled: boolean = true) {
    Column({ space: 6 }) {
      Text(label).fontSize(14).fontColor('#475467')
      TextInput({ text: value })
        .type(inputType)
        .height(44)
        .backgroundColor('#F2F4F7')
        .borderRadius(10)
        .onChange(onChanged)
        .enabled(!this.isRecording && enabled)
    }.alignItems(HorizontalAlign.Start).width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        Column({ space: 5 }) {
          Text('Geomag Capture').fontSize(28).fontWeight(FontWeight.Bold).fontColor('#101828')
          Text('HarmonyOS · 地磁与惯性数据采集').fontSize(14).fontColor('#667085')
        }.alignItems(HorizontalAlign.Start).width('100%')

        Row({ space: 8 }) {
          Button('房间建图')
            .layoutWeight(1)
            .backgroundColor(this.roomMappingMode ? '#1677FF' : '#EAECF0')
            .fontColor(this.roomMappingMode ? Color.White : '#344054')
            .onClick(() => { if (!this.isRecording) this.roomMappingMode = true; })
          Button('自由采集')
            .layoutWeight(1)
            .backgroundColor(!this.roomMappingMode ? '#1677FF' : '#EAECF0')
            .fontColor(!this.roomMappingMode ? Color.White : '#344054')
            .onClick(() => { if (!this.isRecording) this.roomMappingMode = false; })
        }.width('100%')

        Column({ space: 12 }) {
          this.sectionTitle('采集信息', '所有采集使用同一房间坐标系，单位为米')
          this.labeledInput('数据集名称', this.datasetName, (value: string) => { this.datasetName = value; })
          this.labeledInput('坐标系名称', this.coordinateFrame, (value: string) => { this.coordinateFrame = value; })
          Row({ space: 10 }) {
            Column() { this.labeledInput(this.roomMappingMode ? '扫描区域左下角 X' : '起点 X', this.startX,
              (value: string) => { this.startX = value; }, InputType.Normal) }.layoutWeight(1)
            Column() { this.labeledInput(this.roomMappingMode ? '扫描区域左下角 Y' : '起点 Y', this.startY,
              (value: string) => { this.startY = value; }, InputType.Normal) }.layoutWeight(1)
          }.width('100%')
          this.labeledInput(this.plannedRoute().length > 0 ? '初始航向（由路线自动计算）' : '初始航向（数学角度）',
            this.plannedRoute().length > 0 ? this.plannedInitialHeadingText() : this.initialHeading,
            (value: string) => { this.initialHeading = value; }, InputType.Normal, this.plannedRoute().length === 0)
        }.padding(16).backgroundColor(Color.White).borderRadius(16).width('100%')

        if (this.roomMappingMode) {
          Column({ space: 12 }) {
            this.sectionTitle('蛇形建图任务', '起点为可扫描区域左下角；建议线距 0.4～0.6 m')
            Row({ space: 10 }) {
              Column() { this.labeledInput('可扫描宽度 X', this.roomWidth, (value: string) => { this.roomWidth = value; }, InputType.Normal) }.layoutWeight(1)
              Column() { this.labeledInput('可扫描长度 Y', this.roomLength, (value: string) => { this.roomLength = value; }, InputType.Normal) }.layoutWeight(1)
            }.width('100%')
            if (this.scanRouteMode === 'long_cross') {
              this.labeledInput('横穿间距（0.5～2.0 m）', this.supplementSpacing,
                (value: string) => { this.supplementSpacing = value; }, InputType.Normal)
            } else {
              this.labeledInput('扫描线距（0.2～1.0 m）', this.lineSpacing,
                (value: string) => { this.lineSpacing = value; }, InputType.Normal)
            }
            Row({ space: 8 }) {
              Button('基础蛇形')
                .layoutWeight(1)
                .backgroundColor(this.scanRouteMode === 'single' ? '#1677FF' : '#EAECF0')
                .fontColor(this.scanRouteMode === 'single' ? Color.White : '#344054')
                .onClick(() => { if (!this.isRecording) this.scanRouteMode = 'single'; })
              Button('双向交叉')
                .layoutWeight(1)
                .backgroundColor(this.scanRouteMode === 'cross' ? '#1677FF' : '#EAECF0')
                .fontColor(this.scanRouteMode === 'cross' ? Color.White : '#344054')
                .onClick(() => { if (!this.isRecording) this.scanRouteMode = 'cross'; })
            }.width('100%')
            Button('横穿长边补扫')
              .width('100%')
              .backgroundColor(this.scanRouteMode === 'long_cross' ? '#7F56D9' : '#EAECF0')
              .fontColor(this.scanRouteMode === 'long_cross' ? Color.White : '#344054')
              .onClick(() => { if (!this.isRecording) this.scanRouteMode = 'long_cross'; })
            Row({ space: 8 }) {
              Button('正向路线')
                .layoutWeight(1)
                .backgroundColor(!this.reverseRouteMode ? '#12B76A' : '#EAECF0')
                .fontColor(!this.reverseRouteMode ? Color.White : '#344054')
                .onClick(() => { if (!this.isRecording) this.reverseRouteMode = false; })
              Button('反向路线')
                .layoutWeight(1)
                .backgroundColor(this.reverseRouteMode ? '#12B76A' : '#EAECF0')
                .fontColor(this.reverseRouteMode ? Color.White : '#344054')
                .onClick(() => { if (!this.isRecording) this.reverseRouteMode = true; })
            }.width('100%')
            Text(this.plannedRouteSummary()).fontSize(12).fontColor('#027A48')
            Text(`${this.scanRouteMode === 'cross' ? '横向完成后从最近端点继续纵向扫描，精度更高。' :
              this.scanRouteMode === 'long_cross' ? '自动判断长边方向，以垂直于长边的路线补充横向磁场约束。' :
                '进行基础横向蛇形扫描，点位较少。'} 预计 ${this.plannedRoutePointCount()} 个点位。`)
              .fontSize(12).fontColor('#667085')
            Button('查看障碍物处理流程').width('100%').backgroundColor('#FFF4E5').fontColor('#B54708')
              .onClick(() => { this.showObstacleGuide(); })
          }.padding(16).backgroundColor(Color.White).borderRadius(16).width('100%')
        } else {
          Column({ space: 12 }) {
            this.sectionTitle('自由采集真实路线', '可选；按实际行走顺序填写拐点坐标，单位为米')
            this.labeledInput('真实路线坐标', this.freeRouteText,
              (value: string) => { this.freeRouteText = value; }, InputType.Normal)
            Text('格式：0,0; 0.6,1.2; 1.2,0。不要把房间边界尺寸当作实际行走坐标。')
              .fontSize(12).fontColor('#667085')
            Row({ space: 8 }) {
              Button('正向路线')
                .layoutWeight(1)
                .backgroundColor(!this.reverseRouteMode ? '#12B76A' : '#EAECF0')
                .fontColor(!this.reverseRouteMode ? Color.White : '#344054')
                .onClick(() => { if (!this.isRecording) this.reverseRouteMode = false; })
              Button('反向路线')
                .layoutWeight(1)
                .backgroundColor(this.reverseRouteMode ? '#12B76A' : '#EAECF0')
                .fontColor(this.reverseRouteMode ? Color.White : '#344054')
                .onClick(() => { if (!this.isRecording) this.reverseRouteMode = true; })
            }.width('100%')
            Text(this.freeRouteStatus()).fontSize(12)
              .fontColor(this.freeRouteText.trim().length > 0 &&
                (this.plannedRoute().length === 0 || RoutePlanner.routeIssue(this.plannedRoute()).length > 0)
                ? '#B42318' : '#027A48')
          }.padding(16).backgroundColor(Color.White).borderRadius(16).width('100%')
        }

        Column({ space: 12 }) {
          Column({ space: 3 }) {
            Text('实时状态').fontSize(19).fontWeight(FontWeight.Bold).fontColor('#172033')
            Text(this.statusMessage).fontSize(13).fontColor('#667085')
          }.alignItems(HorizontalAlign.Start).width('100%')
          Row() {
            Text(this.elapsedText).fontSize(24).fontWeight(FontWeight.Bold).fontColor('#1677FF')
            Blank()
            Text(this.magneticText).fontSize(20).fontWeight(FontWeight.Medium).fontColor('#12B76A')
          }.width('100%')
          Text(this.sensorCountText).fontSize(13).fontColor('#475467')
          Text(this.attitudeText).fontSize(13).fontColor(this.recorder.phoneIsFlat() ? '#027A48' : '#B54708')
          if (!this.recorder.phoneIsFlat() && this.isRecording) {
            Text('手机倾斜超过 15°：保持正面朝上后再确认点位或标记转弯。')
              .fontSize(13).fontColor('#B54708')
          }
          if (this.currentRoutePointCount() > 0 && this.isRecording) {
            Text(`${this.routePhase} · 路线进度 ${this.routeProgress} · ${this.nextRoutePoint}`)
              .fontSize(14).fontColor('#344054')
          }
        }.padding(16).backgroundColor(Color.White).borderRadius(16).width('100%')

        if (!this.isRecording) {
          Button('开始采集', { type: ButtonType.Capsule })
            .height(52).width('100%').backgroundColor('#1677FF').fontColor(Color.White)
            .fontSize(18).fontWeight(FontWeight.Bold).enabled(!this.isBusy)
            .onClick(() => { this.startCapture(); })
        } else {
          Column({ space: 10 }) {
            Row({ space: 10 }) {
              Button(this.isPaused ? '恢复采集' : '暂停采集').layoutWeight(1)
                .backgroundColor(this.isPaused ? '#12B76A' : '#F79009')
                .onClick(() => { this.recorder.togglePause(); this.refreshViewState(); })
              Button('转弯前标记').layoutWeight(1).backgroundColor('#7F56D9').enabled(!this.isPaused)
                .onClick(() => { this.recorder.recordTurn(); this.refreshViewState(); })
            }.width('100%')
            if (this.currentRoutePointCount() > 0) {
              Row({ space: 10 }) {
                Button(this.recorder.nextRouteIndex >= this.currentRoutePointCount() - 1
                  ? '到达终点' : (this.recorder.nextRoutePointRequiresTurn()
                    ? '到达点位并准备转弯' : '到达路线点')).layoutWeight(1).backgroundColor('#1677FF')
                  .enabled(!this.isPaused && this.recorder.phoneIsFlat())
                  .onClick(() => { this.recorder.recordNextRoutePointAndTurn(); this.refreshViewState(); })
                Button('障碍物：跳过此点').layoutWeight(1).backgroundColor('#D92D20').enabled(this.isPaused)
                  .onClick(() => { this.recorder.skipNextRoutePoint(); this.refreshViewState(); })
              }.width('100%')
              Button('撤销上一个路线点').width('100%').backgroundColor('#EAECF0').fontColor('#344054')
                .enabled(!this.isPaused).onClick(() => { this.recorder.undoLastRouteEvent(); this.refreshViewState(); })
            }
            Button('停止并保存').width('100%').backgroundColor('#344054').onClick(() => { this.stopCapture(); })
          }.width('100%')
        }

        if (this.isRecording) {
          Column({ space: 10 }) {
            this.sectionTitle('补充已知坐标锚点', '绕过障碍物后，在已知坐标处立即记录')
            Row({ space: 10 }) {
              TextInput({ text: this.manualAnchorX, placeholder: 'X' }).type(InputType.Normal).layoutWeight(1)
                .backgroundColor('#F2F4F7').onChange((value: string) => { this.manualAnchorX = value; })
              TextInput({ text: this.manualAnchorY, placeholder: 'Y' }).type(InputType.Normal).layoutWeight(1)
                .backgroundColor('#F2F4F7').onChange((value: string) => { this.manualAnchorY = value; })
              Button('记录').backgroundColor('#12B76A').enabled(!this.isPaused)
                .onClick(() => { this.recordManualAnchor(); })
            }.width('100%')
          }.padding(16).backgroundColor(Color.White).borderRadius(16).width('100%')
        }

        Column({ space: 10 }) {
          Column({ space: 3 }) {
            Text('采集包').fontSize(19).fontWeight(FontWeight.Bold).fontColor('#172033')
            Text(this.packageStatus).fontSize(13).fontColor('#667085')
          }.alignItems(HorizontalAlign.Start).width('100%')
          Button('导出 .geomagcapture.zip').width('100%').backgroundColor('#1677FF')
            .enabled(this.hasExportPackage && !this.isBusy)
            .onClick(() => { this.exportPackage(); })
          Text('传到 Mac 后解压，再在 GeomagMac Native 中选择 .geomagcapture 文件夹。')
            .fontSize(12).fontColor('#667085')
        }.padding(16).backgroundColor(Color.White).borderRadius(16).width('100%')

        if (this.errorMessage.length > 0) {
          Text(this.errorMessage).fontSize(14).fontColor('#B42318').padding(12)
            .backgroundColor('#FEF3F2').borderRadius(10).width('100%')
        }

        Column({ space: 6 }) {
          Text('采集提示').fontSize(16).fontWeight(FontWeight.Bold)
          Text('手机正面朝上、前端朝前。预设路线时，到达点位后点“到达点位并准备转弯”，应用会同时记录锚点和转弯起点，然后再转向；无预设路线时才单独标记转弯。')
            .fontSize(13).fontColor('#475467').lineHeight(20)
        }.alignItems(HorizontalAlign.Start).padding(16).backgroundColor('#EEF4FF').borderRadius(16).width('100%')
      }
      .padding({ left: 16, right: 16, top: 18, bottom: 32 })
      .width('100%')
      .backgroundColor('#F2F4F7')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F4F7')
  }
}
