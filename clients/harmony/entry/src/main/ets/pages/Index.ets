import { bundleManager, common } from '@kit.AbilityKit';
import {
  ChatMessage,
  AgentInfo,
  HistorySession,
  MessageActivity,
  MessageArtifact,
  ModelOptionInfo,
  ModelProviderInfo,
  ProfileKey,
  SingleAgentSnapshot,
  SpeechBackend
} from '../models/SingleAgentState';
import {
  SingleAgentController,
  SnapshotListener
} from '../services/SingleAgentController';
import { DEFAULT_GATEWAY_URL } from '../services/AppSettingsStore';
import { VoiceOption } from '../services/SystemSpeechService';

const COLOR_BG = '#08090A';
const COLOR_PANEL = '#111315';
const COLOR_LINE = '#292C31';
const COLOR_TEXT = '#F1F3F5';
const COLOR_MUTED = '#989FA9';
const COLOR_ACCENT = '#737DFF';
const COLOR_SUCCESS = '#45C2A3';
const COLOR_DANGER = '#E27A84';

class TextSelectItem implements SelectOption {
  value: ResourceStr;

  constructor(value: string) {
    this.value = value;
  }
}

@Entry
@Component
struct Index {
  private controller: SingleAgentController = new SingleAgentController();
  private scroller: Scroller = new Scroller();
  @State snapshot: SingleAgentSnapshot = new SingleAgentSnapshot();
  @State showSettings: boolean = false;
  @State showHistory: boolean = false;
  @State gatewayUrl: string = DEFAULT_GATEWAY_URL;
  @State accessToken: string = '';
  @State hasSavedToken: boolean = false;
  @State controllerReady: boolean = false;
  @State settingsSaving: boolean = false;
  @State selectedProfile: ProfileKey = 'default';
  @State inputText: string = '';
  @State showTextComposer: boolean = false;
  @State speechBackend: SpeechBackend = 'harmony_offline';
  @State voicePerson: number = 0;
  @State speechRate: number = 1;
  @State debugMode: boolean = false;
  @State appVersion: string = '版本信息读取中';
  @State voiceOptions: VoiceOption[] = [];
  @State voiceOptionsLoading: boolean = false;
  @State selectedModelProvider: string = '';
  @State selectedRuntimeModel: string = '';
  @State modelSelectionInitialized: boolean = false;
  @State nowMs: number = Date.now();
  private clockTimer?: number;
  private lastMessageCount: number = 0;
  private lastMessageVersion: number = 0;
  private lastMessageListAtEnd: boolean = true;
  private lastAsrUtteranceActive: boolean = false;

  aboutToAppear(): void {
    this.loadAppVersion();
    const context = getContext(this) as common.UIAbilityContext;
    this.controller.setListener(new SnapshotListener(
      (snapshot: SingleAgentSnapshot): void => {
        const wasNearBottom = this.lastMessageCount === 0 || this.isMessageListNearBottom();
        const messageAdded = snapshot.messages.length > this.lastMessageCount;
        const messagesCleared = snapshot.messages.length === 0 && this.lastMessageCount > 0;
        const speechStarted = snapshot.asrUtteranceActive && !this.lastAsrUtteranceActive;
        const messageVersion = this.messageVersion(snapshot);
        const messagesChanged = messageVersion !== this.lastMessageVersion;
        this.lastMessageCount = snapshot.messages.length;
        this.lastMessageVersion = messageVersion;
        this.lastMessageListAtEnd = wasNearBottom;
        this.lastAsrUtteranceActive = snapshot.asrUtteranceActive;
        this.snapshot = snapshot;
        this.syncModelSelection(snapshot);
        if (!this.showSettings && !this.showHistory &&
          (messageAdded || messagesCleared || messagesChanged || speechStarted)) {
          setTimeout((): void => {
            try {
              if (messagesCleared) {
                this.scroller.scrollEdge(Edge.Top);
              } else if (wasNearBottom) {
                this.scroller.scrollEdge(Edge.Bottom);
              }
            } catch (error) {
              // The list may not be mounted during a settings transition.
            }
          }, 0);
        }
      }
    ));
    this.controller.setContext(context).then((): void => {
      this.finishControllerInitialization();
    }).catch((): void => {
      this.controllerReady = true;
      this.showSettings = false;
    });
    this.clockTimer = setInterval((): void => {
      this.nowMs = Date.now();
    }, 500);
  }

  aboutToDisappear(): void {
    if (this.clockTimer !== undefined) {
      clearInterval(this.clockTimer);
      this.clockTimer = undefined;
    }
  }

  onPageShow(): void {
    if (!this.controllerReady) {
      return;
    }
    const config = this.controller.getConfig();
    if (!this.showSettings && config.accessToken.length > 0 && this.snapshot.connection === 'offline') {
      setTimeout((): void => {
        this.controller.connect();
      }, 200);
    }
  }

  private openSettings(): void {
    const config = this.controller.getConfig();
    this.gatewayUrl = config.gatewayUrl;
    this.accessToken = '';
    this.hasSavedToken = config.accessToken.length > 0;
    this.selectedProfile = config.profile;
    this.speechBackend = config.speechBackend;
    this.voicePerson = config.voicePerson;
    this.speechRate = config.speechRate;
    this.debugMode = config.debugMode;
    this.selectedModelProvider = '';
    this.selectedRuntimeModel = '';
    this.modelSelectionInitialized = false;
    this.showHistory = false;
    this.showTextComposer = false;
    this.showSettings = true;
    this.syncModelSelection(this.snapshot);
    this.loadVoiceOptions();
  }

  private closeSettings(): void {
    this.showSettings = false;
    this.accessToken = '';
  }

  private saveSettings(): void {
    if (this.settingsSaving) {
      return;
    }
    const enteredToken = this.accessToken.trim();
    const currentConfig = this.controller.getConfig();
    const savedToken = currentConfig.accessToken;
    const token = enteredToken.length > 0 ? enteredToken : savedToken;
    const reconnect = this.controller.setConfig({
      gatewayUrl: this.gatewayUrl.trim(),
      accessToken: token,
      profile: this.selectedProfile,
      muted: false,
      speakerphoneEnabled: currentConfig.speakerphoneEnabled,
      debugMode: this.debugMode,
      speechBackend: this.speechBackend,
      voicePerson: this.voicePerson,
      speechRate: this.speechRate
    });
    this.settingsSaving = true;
    this.controller.waitForConfigPersistence().then((): void => {
      this.settingsSaving = false;
      this.accessToken = '';
      this.hasSavedToken = token.length > 0;
      this.showSettings = false;
      if (reconnect) {
        this.controller.disconnect();
      }
      if (reconnect || this.snapshot.connection === 'offline') {
        this.controller.connect();
      }
    }).catch((): void => {
      this.settingsSaving = false;
      this.accessToken = '';
      this.hasSavedToken = currentConfig.accessToken.length > 0;
      this.controller.setConfig(currentConfig);
    });
  }

  private finishControllerInitialization(): void {
    const config = this.controller.getConfig();
    this.gatewayUrl = config.gatewayUrl;
    this.accessToken = '';
    this.hasSavedToken = config.accessToken.length > 0;
    this.selectedProfile = config.profile;
    this.speechBackend = config.speechBackend;
    this.voicePerson = config.voicePerson;
    this.speechRate = config.speechRate;
    this.debugMode = config.debugMode;
    this.controllerReady = true;
    this.showSettings = this.snapshot.credentialState === 'unconfigured' ||
      this.snapshot.credentialState === 'storage_error';
    if (this.showSettings) {
      this.loadVoiceOptions();
      return;
    }
    setTimeout((): void => {
      this.controller.connect();
    }, 0);
  }

  private loadVoiceOptions(): void {
    if (this.voiceOptionsLoading) {
      return;
    }
    this.voiceOptionsLoading = true;
    this.controller.listSystemVoices().then((voices: VoiceOption[]): void => {
      this.voiceOptions = voices;
      if (voices.length > 0 && this.voiceIndex() < 0) {
        this.voicePerson = voices[0].person;
      }
      this.voiceOptionsLoading = false;
    }).catch((): void => {
      this.voiceOptions = [];
      this.voiceOptionsLoading = false;
    });
  }

  private profileSelectItems(): TextSelectItem[] {
    return this.snapshot.agents.map((agent: AgentInfo): TextSelectItem =>
      new TextSelectItem(agent.name));
  }

  private loadAppVersion(): void {
    try {
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT
      );
      this.appVersion = '版本 ' + bundleInfo.versionName + ' (' + String(bundleInfo.versionCode) + ')';
    } catch (_error) {
      this.appVersion = '版本信息不可用';
    }
  }

  private reloadModelOptions(): void {
    this.selectedModelProvider = '';
    this.selectedRuntimeModel = '';
    this.modelSelectionInitialized = false;
    this.controller.loadModelOptions();
  }

  private syncModelSelection(snapshot: SingleAgentSnapshot): void {
    if (!this.showSettings || this.modelSelectionInitialized ||
      snapshot.modelOptionsLoading || snapshot.modelProviders.length === 0) {
      return;
    }
    let provider = snapshot.modelProviders.find((item: ModelProviderInfo): boolean =>
      item.id === snapshot.runtimeProvider || item.name === snapshot.runtimeProvider);
    if (provider === undefined && snapshot.runtimeModel.length > 0) {
      provider = snapshot.modelProviders.find((item: ModelProviderInfo): boolean =>
        item.models.find((model: ModelOptionInfo): boolean =>
          model.id === snapshot.runtimeModel) !== undefined);
    }
    if (provider === undefined) {
      provider = snapshot.modelProviders[0];
    }
    this.selectedModelProvider = provider.id;
    const model = provider.models.find((item: ModelOptionInfo): boolean =>
      item.id === snapshot.runtimeModel) || provider.models[0];
    this.selectedRuntimeModel = model !== undefined ? model.id : '';
    this.modelSelectionInitialized = true;
  }

  private modelProviderItems(): TextSelectItem[] {
    return this.snapshot.modelProviders.map((provider: ModelProviderInfo): TextSelectItem =>
      new TextSelectItem(provider.name));
  }

  private modelProviderIndex(): number {
    const index = this.snapshot.modelProviders.findIndex((provider: ModelProviderInfo): boolean =>
      provider.id === this.selectedModelProvider);
    return Math.max(0, index);
  }

  private selectedModelProviderOption(): ModelProviderInfo | undefined {
    return this.snapshot.modelProviders.find((provider: ModelProviderInfo): boolean =>
      provider.id === this.selectedModelProvider);
  }

  private runtimeModelItems(): TextSelectItem[] {
    const provider = this.selectedModelProviderOption();
    return provider !== undefined
      ? provider.models.map((model: ModelOptionInfo): TextSelectItem => new TextSelectItem(model.label))
      : [];
  }

  private runtimeModelIndex(): number {
    const provider = this.selectedModelProviderOption();
    if (provider === undefined) {
      return 0;
    }
    const index = provider.models.findIndex((model: ModelOptionInfo): boolean =>
      model.id === this.selectedRuntimeModel);
    return Math.max(0, index);
  }

  private selectedModelProviderName(): string {
    return this.selectedModelProviderOption()?.name || '选择 Provider';
  }

  private selectedRuntimeModelLabel(): string {
    const provider = this.selectedModelProviderOption();
    const model = provider?.models.find((item: ModelOptionInfo): boolean =>
      item.id === this.selectedRuntimeModel);
    return model !== undefined ? model.label : '选择模型';
  }

  private selectModelProvider(index: number): void {
    if (index < 0 || index >= this.snapshot.modelProviders.length) {
      return;
    }
    const provider = this.snapshot.modelProviders[index];
    this.selectedModelProvider = provider.id;
    this.selectedRuntimeModel = provider.models.length > 0 ? provider.models[0].id : '';
    this.modelSelectionInitialized = true;
  }

  private canSwitchRuntimeModel(): boolean {
    return this.snapshot.connection === 'online' &&
      this.snapshot.runtimeSessionId.length > 0 &&
      !this.snapshot.agentBusy &&
      !this.snapshot.modelSwitching &&
      this.selectedModelProvider.length > 0 &&
      this.selectedRuntimeModel.length > 0;
  }

  private applyRuntimeModelSwitch(): void {
    this.controller.switchRuntimeModel(this.selectedModelProvider, this.selectedRuntimeModel);
  }

  private profileIndex(profile: ProfileKey): number {
    for (let index = 0; index < this.snapshot.agents.length; index += 1) {
      if (this.snapshot.agents[index].id === profile) {
        return index;
      }
    }
    return 0;
  }

  private selectedAgent(): AgentInfo | undefined {
    return this.snapshot.agents.find((agent: AgentInfo): boolean =>
      agent.id === this.snapshot.selectedProfile);
  }

  private selectedAgentName(): string {
    const agent = this.selectedAgent();
    return agent !== undefined ? agent.name : (this.snapshot.selectedProfile.length > 0
      ? this.snapshot.selectedProfile : 'Agent');
  }

  private selectedAgentInitial(): string {
    const name = this.selectedAgentName();
    return Array.from(name)[0] || 'A';
  }

  private selectedAgentAvatar(): string {
    return this.selectedAgent()?.avatarUrl || '';
  }

  private voiceSelectItems(): TextSelectItem[] {
    return this.voiceOptions.map((voice: VoiceOption): TextSelectItem => new TextSelectItem(voice.label));
  }

  private voiceIndex(): number {
    for (let index = 0; index < this.voiceOptions.length; index += 1) {
      if (this.voiceOptions[index].person === this.voicePerson) {
        return index;
      }
    }
    return -1;
  }

  private sendText(): void {
    const value = this.inputText.trim();
    if (value.length === 0) {
      return;
    }
    if (this.controller.submitText(value)) {
      this.inputText = '';
      this.showTextComposer = false;
    }
  }

  private toggleVoice(): void {
    this.controller.toggleVoice();
  }

  private toggleSpeakerphone(): void {
    this.controller.toggleSpeakerphone();
  }

  private canStopTask(): boolean {
    return this.snapshot.agentBusy ||
      this.snapshot.playback !== 'none' ||
      this.snapshot.ttsState === 'speaking';
  }

  private canSendText(): boolean {
    return this.snapshot.connection === 'online' &&
      this.snapshot.runtimeSessionId.length > 0 &&
      !this.snapshot.conversationLoading &&
      this.inputText.trim().length > 0;
  }

  private switchAgent(profile: ProfileKey): void {
    this.selectedProfile = profile;
    this.controller.switchProfile(profile);
  }

  private showHistoryPanel(): void {
    this.showSettings = false;
    this.showTextComposer = false;
    this.showHistory = true;
    this.controller.listHistory();
  }

  private closeHistoryPanel(): void {
    this.showHistory = false;
  }

  private startNewConversation(): void {
    this.showHistory = false;
    this.showTextComposer = false;
    this.controller.newConversation();
    setTimeout((): void => {
      try {
        this.scroller.scrollEdge(Edge.Top);
      } catch (error) {
      }
    }, 0);
  }

  private statusColor(): string {
    if (this.snapshot.connection === 'online' && this.snapshot.runtimeSessionId.length > 0) {
      return COLOR_SUCCESS;
    }
    if (this.snapshot.connection === 'online' || this.snapshot.connection === 'connecting') {
      return COLOR_ACCENT;
    }
    if (this.snapshot.error.length > 0) {
      return COLOR_DANGER;
    }
    return COLOR_MUTED;
  }

  private statusText(): string {
    if (this.snapshot.connection === 'online') {
      return this.snapshot.runtimeSessionId.length > 0 ? '在线' : '准备中';
    }
    if (this.snapshot.connection === 'connecting') {
      return '连接中';
    }
    return '离线';
  }

  private runtimeText(): string {
    const details: string[] = [];
    if (this.snapshot.runtimeModel.length > 0) {
      details.push(this.snapshot.runtimeModel);
    }
    if (this.snapshot.runtimeProvider.length > 0) {
      details.push(this.snapshot.runtimeProvider);
    }
    return details.length > 0 ? details.join(' · ') : '模型加载中';
  }

  private asrStatusText(): string {
    if (this.snapshot.asrState === 'connecting') {
      if (this.snapshot.asrBackend === 'harmony_offline' &&
        this.snapshot.statusDetail.startsWith('本地 ASR：')) {
        return this.snapshot.statusDetail.substring('本地 ASR：'.length);
      }
      return this.snapshot.asrBackend === 'harmony_offline' ? '启动中' : '连接中';
    }
    if (this.snapshot.asrState === 'listening') {
      return '监听中';
    }
    if (this.snapshot.asrState === 'finalizing') {
      return '提交中';
    }
    return '未启动';
  }

  private microphoneButtonText(): string {
    const label = this.snapshot.voiceEnabled ? '麦克风已开' : '开启麦克风';
    if (this.snapshot.voiceEnabled && this.snapshot.microphoneRoute.length > 0) {
      const route = this.snapshot.microphoneRoute.includes('耳机') ? '耳机' : '手机';
      return label + '（' + route + '）';
    }
    return label;
  }

  private outputRouteText(): string {
    if (this.snapshot.audioOutputRoute === 'headset') {
      return '耳机';
    }
    return this.snapshot.audioOutputRoute === 'speaker' ? '扬声器' : '听筒';
  }

  private ttsStatusText(): string {
    if (this.snapshot.ttsState === 'connecting') {
      return '连接中';
    }
    if (this.snapshot.ttsState === 'speaking') {
      return '播报中';
    }
    if (this.snapshot.ttsState === 'ready') {
      return '待命';
    }
    if (this.snapshot.ttsState === 'fallback') {
      return '降级';
    }
    if (this.snapshot.ttsState === 'error') {
      return '错误';
    }
    return '未启动';
  }

  private voiceBackendText(): string {
    if (this.snapshot.asrBackend === 'harmony_offline' &&
      this.snapshot.ttsBackend === 'harmony_offline') {
      return '鸿蒙离线';
    }
    return '远端语音';
  }

  private historyDate(value: number | undefined): string {
    if (value === undefined || value <= 0) {
      return '';
    }
    const millis = value < 100000000000 ? value * 1000 : value;
    const date = new Date(millis);
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    const hour = String(date.getHours()).padStart(2, '0');
    const minute = String(date.getMinutes()).padStart(2, '0');
    return month + '-' + day + ' ' + hour + ':' + minute;
  }

  private historyMeta(item: HistorySession): string {
    const parts: string[] = [];
    const date = this.historyDate(item.started_at !== undefined ? item.started_at : item.updated_at);
    if (date.length > 0) {
      parts.push(date);
    }
    parts.push(String(item.message_count) + ' 条');
    if (item.source.length > 0) {
      parts.push(item.source);
    }
    return parts.join(' · ');
  }

  private formatBytes(size: number): string {
    if (size < 1024) {
      return String(size) + ' B';
    }
    if (size < 1024 * 1024) {
      return (size / 1024).toFixed(1) + ' KB';
    }
    return (size / (1024 * 1024)).toFixed(1) + ' MB';
  }

  private messageTime(timestamp: number): string {
    if (timestamp <= 0) {
      return '时间未知';
    }
    const millis = timestamp < 100000000000 ? timestamp * 1000 : timestamp;
    const date = new Date(millis);
    const now = new Date();
    const hour = String(date.getHours()).padStart(2, '0');
    const minute = String(date.getMinutes()).padStart(2, '0');
    const second = String(date.getSeconds()).padStart(2, '0');
    if (date.getFullYear() === now.getFullYear() &&
      date.getMonth() === now.getMonth() &&
      date.getDate() === now.getDate()) {
      return hour + ':' + minute + ':' + second;
    }
    const year = String(date.getFullYear());
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return year + '-' + month + '-' + day + ' ' + hour + ':' + minute + ':' + second;
  }

  private durationText(value: number | undefined): string {
    if (value === undefined || value < 0) {
      return '';
    }
    return value.toFixed(1) + 's';
  }

  private elapsedSeconds(message: ChatMessage): number {
    if (!message.pending && message.duration_s !== undefined) {
      return message.duration_s;
    }
    const startedAt = message.timestamp < 100000000000 ? message.timestamp * 1000 : message.timestamp;
    return startedAt > 0 ? Math.max(0, this.nowMs - startedAt) / 1000 : 0;
  }

  private hasMessageProcess(message: ChatMessage): boolean {
    return message.role === 'assistant' &&
      (message.pending || message.thinking.length > 0 || message.activities.length > 0 ||
        message.model.length > 0 || message.provider.length > 0 || message.duration_s !== undefined);
  }

  private processSummary(message: ChatMessage): string {
    const parts: string[] = [];
    if (message.pending) {
      parts.push('处理中');
    }
    if (message.model.length > 0) {
      parts.push(message.model);
    }
    if (message.provider.length > 0) {
      parts.push(message.provider);
    }
    const duration = message.pending
      ? this.durationText(this.elapsedSeconds(message)) : this.durationText(message.duration_s);
    if (duration.length > 0) {
      parts.push(duration);
    }
    return parts.length > 0 ? parts.join(' · ') : '过程';
  }

  private messageTiming(message: ChatMessage): string {
    const timestamp = message.role === 'assistant' && message.completedAt > 0
      ? message.completedAt : message.timestamp;
    return this.messageTime(timestamp);
  }

  private userMessageText(message: ChatMessage): string {
    if (message.status === 'listening') {
      return '…';
    }
    return message.status.length > 0 ? message.status : '…';
  }

  private messageVersion(snapshot: SingleAgentSnapshot): number {
    let version = snapshot.messages.length;
    for (const message of snapshot.messages) {
      version = (version * 31 + message.revision + message.text.length) % 2147483647;
    }
    return version;
  }

  private isMessageListNearBottom(): boolean {
    try {
      return this.scroller.isAtEnd();
    } catch (error) {
      return this.lastMessageListAtEnd;
    }
  }

  private activityColor(activity: MessageActivity): string {
    if (activity.state === 'error') {
      return COLOR_DANGER;
    }
    if (activity.state === 'completed') {
      return COLOR_SUCCESS;
    }
    return COLOR_ACCENT;
  }

  private thinkingLines(text: string): string[] {
    const lines: string[] = [];
    const sourceLines = text.replace(/\r\n?/g, '\n').split('\n');
    const boundaries = '。！？!?；;';
    for (const source of sourceLines) {
      let pending = '';
      for (const char of source) {
        pending += char;
        if (boundaries.includes(char)) {
          const value = pending.trim();
          if (value.length > 0) {
            lines.push(value);
          }
          pending = '';
        }
      }
      const tail = pending.trim();
      if (tail.length > 0) {
        lines.push(tail);
      }
    }
    return lines;
  }

  @Builder
  private Header() {
    Row({ space: 8 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: 42, height: 42 })
          .fill('#25284A')
        if (this.selectedAgentAvatar().length > 0) {
          Image(this.selectedAgentAvatar())
            .width(42)
            .height(42)
            .objectFit(ImageFit.Cover)
            .borderRadius(21)
        } else {
          Text(this.selectedAgentInitial())
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#C9C9FF')
        }
      }
      .width(42)
      .height(42)

      Column({ space: 5 }) {
        Row({ space: 6 }) {
          Select(this.profileSelectItems())
            .selected(this.profileIndex(this.snapshot.selectedProfile))
            .value(this.selectedAgentName())
            .font({ size: 12 })
            .fontColor(COLOR_TEXT)
            .backgroundColor(COLOR_BG)
            .border({ width: 1, color: COLOR_LINE })
            .borderRadius(7)
            .layoutWeight(1)
            .height(40)
            .enabled(!this.snapshot.agentBusy && this.snapshot.connection === 'online' && this.snapshot.agents.length > 1)
            .opacity(!this.snapshot.agentBusy && this.snapshot.connection === 'online' && this.snapshot.agents.length > 1 ? 1 : 0.55)
            .onSelect((index: number, _value: string): void => {
              if (index >= 0 && index < this.snapshot.agents.length) {
                this.switchAgent(this.snapshot.agents[index].id);
              }
            })
        }
        .width('100%')

        Row({ space: 5 }) {
          Circle({ width: 6, height: 6 })
            .fill(this.statusColor())
          Text(this.statusText())
            .fontSize(10)
            .fontColor(this.statusColor())
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column({ space: 9 }) {
        Text('Daiworld Voice')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_TEXT)

        Row({ space: 6 }) {
          Button('历史', { type: ButtonType.Normal })
            .width(54)
            .height(30)
            .padding(0)
            .fontSize(10)
            .fontColor(this.showHistory ? COLOR_ACCENT : COLOR_TEXT)
            .backgroundColor(this.showHistory ? '#1C2033' : COLOR_PANEL)
            .border({ width: 1, color: this.showHistory ? COLOR_ACCENT : COLOR_LINE })
            .borderRadius(6)
            .onClick(() => {
              this.showHistoryPanel();
            })

          Button('设置', { type: ButtonType.Normal })
            .width(54)
            .height(30)
            .padding(0)
            .fontSize(10)
            .fontColor(this.showSettings ? COLOR_ACCENT : COLOR_TEXT)
            .backgroundColor(this.showSettings ? '#1C2033' : COLOR_PANEL)
            .border({ width: 1, color: this.showSettings ? COLOR_ACCENT : COLOR_LINE })
            .borderRadius(6)
            .onClick(() => {
              this.openSettings();
            })
        }
      }
      .width(114)
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .height(112)
    .padding({ left: 16, right: 16, top: 12, bottom: 11 })
    .border({ width: { bottom: 1 }, color: COLOR_LINE })
  }

  @Builder
  private SettingsPanel() {
    Scroll() {
      Column({ space: 18 }) {
        Row({ space: 8 }) {
          Text('设置')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_TEXT)
            .layoutWeight(1)
          Button('关闭', { type: ButtonType.Normal })
            .height(34)
            .fontSize(12)
            .fontColor(COLOR_TEXT)
            .backgroundColor(COLOR_BG)
            .border({ width: 1, color: COLOR_LINE })
            .borderRadius(7)
            .onClick(() => {
              this.closeSettings();
            })
        }
        .width('100%')

        Column({ space: 10 }) {
          Text('连接')
            .width('100%')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_TEXT)

          Row({ space: 10 }) {
            Column({ space: 5 }) {
              Text('远端地址')
                .fontSize(11)
                .fontColor(COLOR_MUTED)
                .width('100%')
              TextInput({ placeholder: '网关地址', text: this.gatewayUrl })
                .fontSize(13)
                .fontColor(COLOR_TEXT)
                .placeholderColor(COLOR_MUTED)
                .caretColor(COLOR_TEXT)
                .height(42)
                .padding({ left: 12, right: 12 })
                .backgroundColor(COLOR_BG)
                .border({ width: 1, color: COLOR_LINE })
                .borderRadius(7)
                .onChange((value: string) => {
                  this.gatewayUrl = value;
                })
            }
            .layoutWeight(1)

            Column({ space: 5 }) {
              Text('访问口令')
                .fontSize(11)
                .fontColor(COLOR_MUTED)
                .width('100%')
              TextInput({
                placeholder: this.hasSavedToken ? '已保存，留空不修改' : '访问口令',
                text: this.accessToken
              })
                .fontSize(13)
                .fontColor(COLOR_TEXT)
                .placeholderColor(COLOR_MUTED)
                .caretColor(COLOR_TEXT)
                .height(42)
                .padding({ left: 12, right: 12 })
                .backgroundColor(COLOR_BG)
                .border({ width: 1, color: COLOR_LINE })
                .borderRadius(7)
                .type(InputType.Password)
                .onChange((value: string) => {
                  this.accessToken = value;
                })
            }
            .layoutWeight(1)
          }
          .width('100%')

          if (this.snapshot.credentialState === 'storage_error') {
            Text(this.snapshot.credentialError.length > 0
              ? this.snapshot.credentialError : '访问口令本地存储不可用，请重新保存')
              .width('100%')
              .fontSize(11)
              .lineHeight(17)
              .fontColor(COLOR_DANGER)
          } else if (this.snapshot.credentialState === 'unauthorized') {
            Text('已保存的访问口令未通过服务器验证，请输入新的口令')
              .width('100%')
              .fontSize(11)
              .lineHeight(17)
              .fontColor(COLOR_DANGER)
          }

        }
        .width('100%')
        .padding(12)
        .backgroundColor(COLOR_PANEL)
        .border({ width: 1, color: COLOR_LINE })
        .borderRadius(9)

        Column({ space: 10 }) {
          Text('Agent 运行配置')
            .width('100%')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_TEXT)

          Row() {
            Text('当前会话')
              .fontSize(13)
              .fontColor(COLOR_TEXT)
            Blank()
            Text(this.runtimeText())
              .constraintSize({ maxWidth: 190 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontSize(11)
              .fontColor(COLOR_SUCCESS)
          }
          .width('100%')

          Text('只切换当前 Session，不修改 Agent 的默认配置，也不会重建对话或语音连接。')
            .width('100%')
            .fontSize(11)
            .lineHeight(17)
            .fontColor(COLOR_MUTED)

          if (this.snapshot.modelOptionsLoading) {
            Row({ space: 8 }) {
              LoadingProgress()
                .width(18)
                .height(18)
                .color(COLOR_ACCENT)
              Text('正在读取 Provider 和模型')
                .fontSize(12)
                .fontColor(COLOR_MUTED)
            }
            .width('100%')
            .height(42)
          } else if (this.snapshot.modelOptionsError.length > 0) {
            Row({ space: 8 }) {
              Text(this.snapshot.modelOptionsError)
                .layoutWeight(1)
                .fontSize(11)
                .fontColor(COLOR_DANGER)
              Button('重新加载', { type: ButtonType.Normal })
                .height(32)
                .fontSize(10)
                .fontColor(COLOR_TEXT)
                .backgroundColor(COLOR_BG)
                .border({ width: 1, color: COLOR_LINE })
                .borderRadius(6)
                .onClick(() => {
                  this.reloadModelOptions();
                })
            }
            .width('100%')
          } else if (this.snapshot.modelProviders.length > 0) {
            Row({ space: 10 }) {
              Column({ space: 5 }) {
                Text('Provider')
                  .width('100%')
                  .fontSize(11)
                  .fontColor(COLOR_MUTED)
                Select(this.modelProviderItems())
                  .selected(this.modelProviderIndex())
                  .value(this.selectedModelProviderName())
                  .font({ size: 13 })
                  .fontColor(COLOR_TEXT)
                  .backgroundColor(COLOR_BG)
                  .border({ width: 1, color: COLOR_LINE })
                  .borderRadius(7)
                  .width('100%')
                  .height(44)
                  .enabled(!this.snapshot.modelSwitching)
                  .onSelect((index: number, _value: string): void => {
                    this.selectModelProvider(index);
                  })
              }
              .layoutWeight(1)

              Column({ space: 5 }) {
                Text('模型')
                  .width('100%')
                  .fontSize(11)
                  .fontColor(COLOR_MUTED)
                Select(this.runtimeModelItems())
                  .selected(this.runtimeModelIndex())
                  .value(this.selectedRuntimeModelLabel())
                  .font({ size: 13 })
                  .fontColor(COLOR_TEXT)
                  .backgroundColor(COLOR_BG)
                  .border({ width: 1, color: COLOR_LINE })
                  .borderRadius(7)
                  .width('100%')
                  .height(44)
                  .enabled(!this.snapshot.modelSwitching)
                  .onSelect((index: number, _value: string): void => {
                    const provider = this.selectedModelProviderOption();
                    if (provider !== undefined && index >= 0 && index < provider.models.length) {
                      this.selectedRuntimeModel = provider.models[index].id;
                    }
                  })
              }
              .layoutWeight(1)
            }
            .width('100%')

            if (this.snapshot.modelSwitchStatus.length > 0) {
              Text(this.snapshot.modelSwitchStatus)
                .width('100%')
                .fontSize(11)
                .fontColor(COLOR_SUCCESS)
            }
            if (this.snapshot.modelSwitchError.length > 0) {
              Text(this.snapshot.modelSwitchError)
                .width('100%')
                .fontSize(11)
                .lineHeight(17)
                .fontColor(COLOR_DANGER)
            }

            Button(this.snapshot.modelSwitching ? '切换并确认中…' : '切换当前会话', {
              type: ButtonType.Normal
            })
              .width('100%')
              .height(40)
              .fontSize(12)
              .fontColor(COLOR_BG)
              .backgroundColor(COLOR_SUCCESS)
              .borderRadius(7)
              .enabled(this.canSwitchRuntimeModel())
              .opacity(this.canSwitchRuntimeModel() ? 1 : 0.5)
              .onClick(() => {
                this.applyRuntimeModelSwitch();
              })
          } else {
            Text('暂无可用的 Provider / 模型选项')
              .width('100%')
              .fontSize(12)
              .fontColor(COLOR_MUTED)
          }
        }
        .width('100%')
        .padding(12)
        .backgroundColor(COLOR_PANEL)
        .border({ width: 1, color: COLOR_LINE })
        .borderRadius(9)

        Column({ space: 10 }) {
          Text('语音引擎')
            .width('100%')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_TEXT)

          Row() {
            Button('鸿蒙离线', { type: ButtonType.Normal })
              .layoutWeight(1)
              .height(38)
              .fontSize(12)
              .fontColor(this.speechBackend === 'harmony_offline' ? COLOR_BG : COLOR_MUTED)
              .backgroundColor(this.speechBackend === 'harmony_offline' ? COLOR_SUCCESS : COLOR_BG)
              .borderRadius({ topLeft: 6, bottomLeft: 6, topRight: 0, bottomRight: 0 })
              .onClick(() => {
                this.speechBackend = 'harmony_offline';
                this.loadVoiceOptions();
              })
            Button('远端 API', { type: ButtonType.Normal })
              .layoutWeight(1)
              .height(38)
              .fontSize(12)
              .fontColor(this.speechBackend === 'remote' ? COLOR_BG : COLOR_MUTED)
              .backgroundColor(this.speechBackend === 'remote' ? COLOR_ACCENT : COLOR_BG)
              .borderRadius({ topLeft: 0, bottomLeft: 0, topRight: 6, bottomRight: 6 })
              .onClick(() => {
                this.speechBackend = 'remote';
              })
          }
          .width('100%')
          .padding(3)
          .backgroundColor(COLOR_BG)
          .borderRadius(7)

          Row({ space: 10 }) {
            Column({ space: 5 }) {
              Text('音色')
                .width('100%')
                .fontSize(11)
                .fontColor(COLOR_MUTED)
              if (this.speechBackend === 'harmony_offline') {
                if (this.voiceOptionsLoading) {
                  Row({ space: 8 }) {
                    LoadingProgress()
                      .width(18)
                      .height(18)
                      .color(COLOR_ACCENT)
                    Text('读取中')
                      .fontSize(12)
                      .fontColor(COLOR_MUTED)
                  }
                  .width('100%')
                  .height(44)
                } else if (this.voiceOptions.length > 0) {
                  Select(this.voiceSelectItems())
                    .selected(Math.max(0, this.voiceIndex()))
                    .value(this.voiceOptions[Math.max(0, this.voiceIndex())].label)
                    .font({ size: 13 })
                    .fontColor(COLOR_TEXT)
                    .backgroundColor(COLOR_BG)
                    .border({ width: 1, color: COLOR_LINE })
                    .borderRadius(7)
                    .width('100%')
                    .height(44)
                    .onSelect((index: number, _value: string): void => {
                      this.voicePerson = this.voiceOptions[index].person;
                    })
                } else {
                  Text('暂无可用音色')
                    .width('100%')
                    .height(44)
                    .fontSize(12)
                    .fontColor(COLOR_DANGER)
                }
              } else {
                Text('远端配置')
                  .width('100%')
                  .height(44)
                  .fontSize(12)
                  .fontColor(COLOR_MUTED)
              }
            }
            .layoutWeight(1)

            Column({ space: 5 }) {
              Row() {
                Text('朗读语速')
                  .fontSize(11)
                  .fontColor(COLOR_MUTED)
                Blank()
                Text(this.speechRate.toFixed(1) + 'x')
                  .fontSize(11)
                  .fontColor(COLOR_SUCCESS)
              }
              .width('100%')
              Row({ space: 6 }) {
                Text('0.5')
                  .fontSize(9)
                  .fontColor(COLOR_MUTED)
                Slider({
                  value: this.speechRate,
                  min: 0.5,
                  max: 2,
                  step: 0.1,
                  style: SliderStyle.OutSet
                })
                  .layoutWeight(1)
                  .selectedColor(COLOR_SUCCESS)
                  .trackColor(COLOR_LINE)
                  .blockColor(COLOR_TEXT)
                  .enabled(this.speechBackend === 'harmony_offline')
                  .opacity(this.speechBackend === 'harmony_offline' ? 1 : 0.45)
                  .onChange((value: number): void => {
                    this.speechRate = Math.round(value * 10) / 10;
                  })
                Text('2.0')
                  .fontSize(9)
                  .fontColor(COLOR_MUTED)
              }
              .width('100%')
              .height(44)
            }
            .layoutWeight(1)
          }
          .width('100%')

          if (this.speechBackend === 'remote') {
            Text('音色由远端语音服务配置；切回本地时会保留当前本地音色和语速。')
              .width('100%')
              .fontSize(11)
              .lineHeight(17)
              .fontColor(COLOR_MUTED)
          }
        }
        .width('100%')
        .padding(12)
        .backgroundColor(COLOR_PANEL)
        .border({ width: 1, color: COLOR_LINE })
        .borderRadius(9)

        Column({ space: 10 }) {
          Text('应用')
            .width('100%')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_TEXT)
          Row() {
            Text('调试模式')
              .fontSize(13)
              .fontColor(COLOR_TEXT)
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.debugMode })
              .selectedColor(COLOR_ACCENT)
              .onChange((isOn: boolean): void => {
                this.debugMode = isOn;
              })
          }
          .width('100%')
          .height(42)
        }
        .width('100%')
        .padding(12)
        .backgroundColor(COLOR_PANEL)
        .border({ width: 1, color: COLOR_LINE })
        .borderRadius(9)

        Button(this.settingsSaving ? '正在安全保存' :
          (this.snapshot.connection === 'online' ? '保存设置' : '保存并连接'), { type: ButtonType.Normal })
          .width('100%')
          .height(44)
          .fontSize(13)
          .fontColor(COLOR_BG)
          .backgroundColor(COLOR_ACCENT)
          .borderRadius(8)
          .enabled(!this.settingsSaving)
          .onClick(() => {
            this.saveSettings();
          })

        Text(this.appVersion)
          .width('100%')
          .textAlign(TextAlign.Center)
          .fontSize(10)
          .fontColor(COLOR_MUTED)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 28 })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
  }

  @Builder
  private HistoryPanel() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('历史对话')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_TEXT)
          .layoutWeight(1)
        Button('关闭', { type: ButtonType.Normal })
          .height(34)
          .fontSize(11)
          .fontColor(COLOR_TEXT)
          .backgroundColor(COLOR_PANEL)
          .border({ width: 1, color: COLOR_LINE })
          .borderRadius(7)
          .onClick(() => {
            this.closeHistoryPanel();
          })
      }
      .width('100%')

      Button('新对话', { type: ButtonType.Normal })
        .width('100%')
        .height(40)
        .fontSize(12)
        .fontColor(COLOR_BG)
        .backgroundColor(COLOR_ACCENT)
        .borderRadius(8)
        .onClick(() => {
          this.startNewConversation();
        })

      if (this.snapshot.history.length === 0) {
        Column({ space: 6 }) {
          Text('暂无历史对话')
            .fontSize(14)
            .fontColor(COLOR_TEXT)
          Text('完成一次对话后会出现在这里')
            .fontSize(12)
            .fontColor(COLOR_MUTED)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.snapshot.history, (item: HistorySession) => {
              Row({ space: 8 }) {
                Column({ space: 3 }) {
                  Text(item.title)
                    .width('100%')
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(COLOR_TEXT)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(item.preview.length > 0 ? item.preview : '暂无内容预览')
                    .width('100%')
                    .fontSize(10)
                    .fontColor(COLOR_MUTED)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.historyMeta(item))
                    .width('100%')
                    .fontSize(9)
                    .fontColor(COLOR_MUTED)
                    .maxLines(1)
                }
                  .layoutWeight(1)
                  .height(68)
                  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                  .alignItems(HorizontalAlign.Start)
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor(item.id === this.snapshot.storedSessionId ? '#1C2033' : COLOR_PANEL)
                  .border({
                    width: 1,
                    color: item.id === this.snapshot.storedSessionId ? COLOR_ACCENT : COLOR_LINE
                  })
                  .borderRadius(7)
                  .onClick(() => {
                    this.controller.resumeSession(item.id);
                    this.showHistory = false;
                  })
                Button(item.id === this.snapshot.storedSessionId ? '当前' : '删除', { type: ButtonType.Normal })
                  .width(56)
                  .height(68)
                  .fontSize(11)
                  .padding(0)
                  .fontColor(item.id === this.snapshot.storedSessionId ? COLOR_MUTED : COLOR_DANGER)
                  .backgroundColor(COLOR_PANEL)
                  .border({ width: 1, color: COLOR_LINE })
                  .borderRadius(7)
                  .enabled(item.id !== this.snapshot.storedSessionId)
                  .opacity(item.id === this.snapshot.storedSessionId ? 0.55 : 1)
                  .onClick(() => {
                    this.controller.deleteSession(item.id);
                  })
              }
              .width('100%')
            }, (item: HistorySession) => item.id)

            if (this.snapshot.historyLoading) {
              Text('正在加载更多...')
                .fontSize(11)
                .fontColor(COLOR_MUTED)
                .padding(12)
            } else if (this.snapshot.historyHasMore) {
              Text('继续下滑加载更多')
                .fontSize(11)
                .fontColor(COLOR_MUTED)
                .padding(12)
            } else {
              Text('已加载全部历史')
                .fontSize(11)
                .fontColor(COLOR_MUTED)
                .padding(12)
            }
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .onReachEnd(() => {
          this.controller.loadMoreHistory();
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  private EmptyState() {
    Column({ space: 8 }) {
      Text('•••')
        .fontSize(30)
        .fontColor('#555B66')
      Text('开始一段实时对话')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_TEXT)
      Text('直接连接一个 Hermes Agent')
        .fontSize(12)
        .fontColor(COLOR_MUTED)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private ControllerLoadingState() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(30)
        .height(30)
        .color(COLOR_ACCENT)
      Text('正在读取安全设置')
        .fontSize(13)
        .fontColor(COLOR_MUTED)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private ConversationLoadingState() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(30)
        .height(30)
        .color(COLOR_ACCENT)
      Text('正在加载对话')
        .fontSize(13)
        .fontColor(COLOR_MUTED)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private ArtifactItem(artifact: MessageArtifact) {
    if (artifact.isImage) {
      Column({ space: 6 }) {
        Image(this.controller.artifactUrl(artifact.token))
          .width('100%')
          .height(180)
          .objectFit(ImageFit.Contain)
          .backgroundColor(COLOR_BG)
        Text(artifact.name + ' · ' + this.formatBytes(artifact.size))
          .width('100%')
          .fontSize(10)
          .fontColor(COLOR_MUTED)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding(8)
      .backgroundColor(COLOR_PANEL)
      .border({ width: 1, color: COLOR_LINE })
      .borderRadius(8)
      .onClick(() => {
        this.controller.openArtifact(artifact);
      })
    } else {
      Row({ space: 10 }) {
        Text('附件')
          .fontSize(11)
          .fontColor(COLOR_ACCENT)
        Column({ space: 3 }) {
          Text(artifact.name)
            .width('100%')
            .fontSize(12)
            .fontColor(COLOR_TEXT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(artifact.mimeType + ' · ' + this.formatBytes(artifact.size))
            .width('100%')
            .fontSize(9)
            .fontColor(COLOR_MUTED)
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text('打开')
          .fontSize(11)
          .fontColor(COLOR_ACCENT)
      }
      .width('100%')
      .height(58)
      .padding({ left: 12, right: 12 })
      .backgroundColor(COLOR_PANEL)
      .border({ width: 1, color: COLOR_LINE })
      .borderRadius(8)
      .onClick(() => {
        this.controller.openArtifact(artifact);
      })
    }
  }

  @Builder
  private ActivityItem(activity: MessageActivity) {
    Row({ space: 8 }) {
      Circle({ width: 6, height: 6 })
        .fill(this.activityColor(activity))
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(activity.title)
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_TEXT)
            .layoutWeight(1)
          if (activity.duration_s !== undefined) {
            Text(this.durationText(activity.duration_s))
              .fontSize(9)
              .fontColor(COLOR_MUTED)
          }
        }
        .width('100%')
        if (activity.detail.length > 0) {
          Text(activity.detail)
            .width('100%')
            .fontSize(10)
            .lineHeight(16)
            .fontColor(activity.state === 'error' ? COLOR_DANGER : COLOR_MUTED)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
  }

  @Builder
  private MessageProcess(message: ChatMessage) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        if (message.pending) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color(COLOR_ACCENT)
        } else {
          Circle({ width: 7, height: 7 })
            .fill(COLOR_SUCCESS)
        }
        Text(this.processSummary(message))
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(message.pending ? COLOR_ACCENT : COLOR_MUTED)
          .layoutWeight(1)
        Text(message.pending || message.processExpanded ? '⌃' : '⌄')
          .fontSize(14)
          .fontColor(COLOR_MUTED)
      }
      .width('100%')
      .height(28)
      .onClick(() => {
        if (!message.pending) {
          this.controller.toggleMessageProcess(message.id);
        }
      })

      if (message.pending || message.processExpanded) {
        if (message.thinking.length > 0) {
          Column({ space: 4 }) {
            Text('思考过程')
              .width('100%')
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLOR_MUTED)
            ForEach(this.thinkingLines(message.thinking), (line: string) => {
              Row({ space: 7 }) {
                Circle({ width: 4, height: 4 })
                  .fill(COLOR_ACCENT)
                Text(line)
                  .fontSize(11)
                  .lineHeight(17)
                  .fontColor(COLOR_TEXT)
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }, (line: string, index: number) => String(index) + '-' + line)
          }
          .width('100%')
        } else if (message.pending && message.activities.length === 0) {
          Text('正在分析请求')
            .width('100%')
            .fontSize(11)
            .fontColor(COLOR_MUTED)
        }

        if (message.activities.length > 0) {
          Column({ space: 8 }) {
            ForEach(message.activities, (activity: MessageActivity) => {
              this.ActivityItem(activity)
            }, (activity: MessageActivity) => activity.id)
          }
          .width('100%')
        }
      }
    }
    .width('92%')
    .padding(10)
    .backgroundColor('#0C0D0F')
    .border({ width: 1, color: COLOR_LINE })
    .borderRadius(8)
  }

  @Builder
  private MessageItem(message: ChatMessage) {
    Column({ space: 5 }) {
      Text(this.messageTiming(message))
        .width('100%')
        .fontSize(9)
        .fontColor(COLOR_MUTED)
        .maxLines(1)
        .textAlign(TextAlign.Center)

      if (message.role === 'assistant' && this.hasMessageProcess(message)) {
        this.MessageProcess(message)
      }

      if (message.role === 'user' && (message.text.length > 0 || message.transient)) {
        Text(message.text.length > 0 ? message.text : this.userMessageText(message))
          .constraintSize({ minWidth: 48, maxWidth: '92%' })
          .padding(12)
          .fontSize(14)
          .lineHeight(22)
          .fontColor(COLOR_TEXT)
          .backgroundColor('#23253C')
          .border({ width: 1, color: '#363A67' })
          .borderRadius(8)
      } else if (message.text.length > 0 || message.pending || message.artifacts.length > 0) {
        Column({ space: 10 }) {
          if (message.text.length > 0) {
            Text(message.text)
              .fontSize(14)
              .lineHeight(22)
              .fontColor(COLOR_TEXT)
          }
          if (message.artifacts.length > 0) {
            Column({ space: 8 }) {
              ForEach(message.artifacts, (artifact: MessageArtifact) => {
                this.ArtifactItem(artifact)
              }, (artifact: MessageArtifact) => artifact.token)
            }
            .width('100%')
          }
          if (message.role === 'assistant' && message.text.length > 0 && !message.pending) {
            Row() {
              Blank()
              Button({ type: ButtonType.Circle }) {
                if (message.replaying) {
                  SymbolGlyph($r('sys.symbol.square_fill'))
                    .fontSize(17)
                    .fontColor([COLOR_DANGER])
                } else {
                  SymbolGlyph($r('sys.symbol.speaker_wave_2'))
                    .fontSize(17)
                    .fontColor([COLOR_ACCENT])
                }
              }
              .width(30)
              .height(30)
              .backgroundColor(message.replaying ? '#311A20' : '#1C2033')
              .enabled(this.controller.canReplayMessage(message))
              .opacity(this.controller.canReplayMessage(message) ? 1 : 0.45)
              .accessibilityText(message.replaying ? '停止重读这条消息' : '重新朗读这条消息')
              .onClick(() => {
                this.controller.replayMessage(message);
              })
            }
            .width('100%')
            .height(30)
          }
        }
        .width('92%')
        .padding(12)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(COLOR_PANEL)
        .border({ width: 1, color: COLOR_LINE })
        .borderRadius(8)
      }

    }
    .width('100%')
    .alignItems(message.role === 'user' ? HorizontalAlign.End : HorizontalAlign.Start)
    .margin({ bottom: 12 })
  }

  @Builder
  private MessageList() {
    Scroll(this.scroller) {
      Column({ space: 0 }) {
        ForEach(this.snapshot.messages, (message: ChatMessage) => {
          this.MessageItem(message)
        }, (message: ChatMessage) => message.id + '-' + String(message.revision))
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .padding({ left: 16, right: 16, top: 12 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .onScroll(() => {
      this.lastMessageListAtEnd = this.isMessageListNearBottom();
    })
  }

  @Builder
  private ErrorBanner() {
    if (typeof this.snapshot.error === 'string' && this.snapshot.error.length > 0) {
      Text(this.snapshot.error)
        .width('100%')
        .fontSize(11)
        .fontColor(COLOR_DANGER)
        .padding({ left: 16, right: 16, bottom: 8 })
    }
  }

  @Builder
  private VoiceStatus() {
    if (this.snapshot.debugMode &&
      (this.snapshot.voiceEnabled || this.snapshot.asrState !== 'stopped' || this.snapshot.ttsState !== 'stopped')) {
      Row({ space: 8 }) {
        Text(this.voiceBackendText())
          .fontSize(10)
          .fontColor(COLOR_MUTED)
        Text('ASR ' + this.asrStatusText())
          .fontSize(10)
          .fontColor(this.snapshot.asrState === 'listening' ? COLOR_SUCCESS : COLOR_MUTED)
        Text('TTS ' + this.ttsStatusText())
          .fontSize(10)
          .fontColor(this.snapshot.ttsState === 'speaking' ? COLOR_SUCCESS : COLOR_MUTED)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8 })
    }
  }

  @Builder
  private Composer() {
    Column() {
      this.VoiceStatus()
      if (this.showTextComposer) {
        Row({ space: 8 }) {
          TextInput({ placeholder: '输入文字', text: this.inputText })
            .fontSize(14)
            .fontColor(COLOR_TEXT)
            .placeholderColor(COLOR_MUTED)
            .caretColor(COLOR_TEXT)
            .height(42)
            .layoutWeight(1)
            .padding({ left: 12, right: 12 })
            .backgroundColor(COLOR_PANEL)
            .border({ width: 1, color: COLOR_LINE })
            .borderRadius(7)
            .onChange((value: string) => {
              this.inputText = value;
            })
            .onSubmit(() => {
              this.sendText();
            })

          Button('发送', { type: ButtonType.Normal })
            .width(64)
            .height(42)
            .fontSize(12)
            .fontColor(this.canSendText() ? COLOR_BG : COLOR_MUTED)
            .backgroundColor(this.canSendText() ? COLOR_ACCENT : COLOR_PANEL)
            .border({ width: 1, color: this.canSendText() ? COLOR_ACCENT : COLOR_LINE })
            .borderRadius(8)
            .enabled(this.canSendText())
            .onClick(() => {
              this.sendText();
            })
        }
        .width('100%')
        .margin({ bottom: 8 })
      }

      Row({ space: 8 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.ohos_mic'))
              .fontSize(21)
              .fontColor([this.snapshot.voiceEnabled ? COLOR_SUCCESS : COLOR_MUTED])
            Text(this.microphoneButtonText())
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.snapshot.voiceEnabled ? COLOR_SUCCESS : COLOR_TEXT)
              .maxLines(1)
          }
        }
          .height(42)
          .layoutWeight(1)
          .padding({ left: 10, right: 10 })
          .backgroundColor(this.snapshot.voiceEnabled ? '#16362D' : COLOR_PANEL)
          .border({ width: 1, color: this.snapshot.voiceEnabled ? COLOR_SUCCESS : COLOR_LINE })
          .borderRadius(8)
          .accessibilityText(this.snapshot.voiceEnabled ? '关闭麦克风' : '开启麦克风')
          .onClick(() => {
            this.toggleVoice();
          })

        Button('停止', { type: ButtonType.Normal })
          .width(62)
          .height(42)
          .fontSize(12)
          .fontColor(this.canStopTask() ? COLOR_DANGER : COLOR_MUTED)
          .backgroundColor(COLOR_PANEL)
          .border({ width: 1, color: this.canStopTask() ? COLOR_DANGER : COLOR_LINE })
          .borderRadius(8)
          .enabled(this.canStopTask())
          .opacity(this.canStopTask() ? 1 : 0.5)
          .onClick(() => {
            this.controller.stopCurrentTask();
          })

        Button({ type: ButtonType.Normal }) {
          Row({ space: 4 }) {
            if (this.snapshot.audioOutputRoute === 'headset') {
              SymbolGlyph($r('sys.symbol.headphones'))
                .fontSize(18)
                .fontColor([COLOR_ACCENT])
            } else if (this.snapshot.audioOutputRoute === 'speaker') {
              SymbolGlyph($r('sys.symbol.speaker_wave_2'))
                .fontSize(18)
                .fontColor([COLOR_ACCENT])
            } else {
              SymbolGlyph($r('sys.symbol.ear'))
                .fontSize(18)
                .fontColor([COLOR_ACCENT])
            }
            Text(this.outputRouteText())
              .fontSize(11)
              .fontColor(COLOR_ACCENT)
              .maxLines(1)
          }
        }
          .width(78)
          .height(42)
          .padding({ left: 6, right: 6 })
          .backgroundColor('#1C2033')
          .border({
            width: 1,
            color: COLOR_ACCENT
          })
          .borderRadius(8)
          .accessibilityText('当前使用' + this.outputRouteText() + '，点击切换输出')
          .onClick(() => {
            this.toggleSpeakerphone();
          })

        Button('文字', { type: ButtonType.Normal })
          .width(62)
          .height(42)
          .fontSize(12)
          .fontColor(this.showTextComposer ? COLOR_ACCENT : COLOR_TEXT)
          .backgroundColor(this.showTextComposer ? '#1C2033' : COLOR_PANEL)
          .border({ width: 1, color: this.showTextComposer ? COLOR_ACCENT : COLOR_LINE })
          .borderRadius(8)
          .onClick(() => {
            this.showTextComposer = !this.showTextComposer;
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 16 })
    .border({ width: { top: 1 }, color: COLOR_LINE })
    .enabled(!this.snapshot.conversationLoading)
    .opacity(this.snapshot.conversationLoading ? 0.55 : 1)
  }

  build() {
    Column() {
      this.Header()
      if (!this.controllerReady) {
        this.ControllerLoadingState()
      } else if (this.showSettings) {
        this.SettingsPanel()
      } else if (this.showHistory) {
        this.HistoryPanel()
      } else {
        if (this.snapshot.conversationLoading) {
          this.ConversationLoadingState()
        } else if (this.snapshot.messages.length === 0 && !this.snapshot.asrUtteranceActive &&
          this.snapshot.asrTranscript.length === 0) {
          this.EmptyState()
        } else {
          this.MessageList()
        }
        this.ErrorBanner()
        this.Composer()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_BG)
  }
}
