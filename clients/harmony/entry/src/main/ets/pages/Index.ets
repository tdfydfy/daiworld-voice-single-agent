import { common } from '@kit.AbilityKit';
import {
  ChatMessage,
  ProfileInfo,
  ProfileKey,
  SingleAgentSnapshot
} from '../models/SingleAgentState';
import { SingleAgentController } from '../services/SingleAgentController';

const COLOR_BG = '#08090A';
const COLOR_PANEL = '#111315';
const COLOR_LINE = '#292C31';
const COLOR_TEXT = '#F1F3F5';
const COLOR_MUTED = '#989FA9';
const COLOR_ACCENT = '#737DFF';
const COLOR_SUCCESS = '#45C2A3';
const COLOR_DANGER = '#E27A84';

@Entry
@Component
struct Index {
  private controller: SingleAgentController = new SingleAgentController();
  private scroller: Scroller = new Scroller();
  @State snapshot: SingleAgentSnapshot = new SingleAgentSnapshot();
  @State showSettings: boolean = false;
  @State gatewayUrl: string = '';
  @State accessToken: string = '';
  @State selectedProfile: ProfileKey = 'default';
  @State inputText: string = '';

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    this.controller.setListener((snapshot: SingleAgentSnapshot) => {
      this.snapshot = snapshot;
      setTimeout((): void => {
        this.scroller.scrollEdge(Edge.Bottom);
      }, 0);
    });
    this.showSettings = this.gatewayUrl.length === 0 || this.accessToken.length === 0;
  }

  private saveSettings(): void {
    this.controller.setConfig({
      gatewayUrl: this.gatewayUrl.trim(),
      accessToken: this.accessToken.trim(),
      profile: this.selectedProfile,
      muted: this.snapshot.voiceEnabled === false
    });
    this.showSettings = false;
    this.controller.connect();
  }

  private sendText(): void {
    const value = this.inputText.trim();
    if (value.length === 0) {
      return;
    }
    this.controller.submitText(value);
    this.inputText = '';
  }

  private toggleVoice(): void {
    this.controller.toggleVoice();
  }

  private statusColor(): string {
    if (this.snapshot.connection === 'online') {
      return COLOR_SUCCESS;
    }
    if (this.snapshot.connection === 'connecting') {
      return COLOR_ACCENT;
    }
    return COLOR_MUTED;
  }

  private statusText(): string {
    if (this.snapshot.connection === 'online') {
      return '在线';
    }
    if (this.snapshot.connection === 'connecting') {
      return '连接中';
    }
    return '离线';
  }

  @Builder
  private Header() {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text('Daiworld Voice')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_TEXT)
        Text(ProfileInfo.displayName(this.snapshot.selectedProfile))
          .fontSize(11)
          .fontColor(COLOR_MUTED)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Circle({ width: 7, height: 7 })
        .fill(this.statusColor())
      Text(this.statusText())
        .fontSize(11)
        .fontColor(this.statusColor())

      Button('设置', { type: ButtonType.Normal })
        .height(34)
        .fontSize(11)
        .fontColor(COLOR_TEXT)
        .backgroundColor(COLOR_PANEL)
        .border({ width: 1, color: COLOR_LINE })
        .borderRadius(7)
        .onClick(() => {
          this.showSettings = true;
        })
    }
    .width('100%')
    .height(76)
    .padding({ left: 16, right: 16 })
    .border({ width: { bottom: 1 }, color: COLOR_LINE })
  }

  @Builder
  private SettingsPanel() {
    Column({ space: 12 }) {
      Text('连接设置')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_TEXT)

      TextInput({ placeholder: '网关地址，例如 https://voice.daiworld.cc.cd', text: this.gatewayUrl })
        .fontSize(13)
        .height(42)
        .onChange((value: string) => {
          this.gatewayUrl = value;
        })

      TextInput({ placeholder: '访问口令', text: this.accessToken })
        .fontSize(13)
        .height(42)
        .type(InputType.Password)
        .onChange((value: string) => {
          this.accessToken = value;
        })

      Row({ space: 8 }) {
        ForEach(ProfileInfo.PROFILES, (key: ProfileKey) => {
          Button(ProfileInfo.displayName(key), { type: ButtonType.Normal })
            .height(34)
            .fontSize(12)
            .fontColor(this.selectedProfile === key ? COLOR_BG : COLOR_TEXT)
            .backgroundColor(this.selectedProfile === key ? COLOR_ACCENT : COLOR_PANEL)
            .borderRadius(7)
            .onClick(() => {
              this.selectedProfile = key;
            })
        }, (key: ProfileKey) => key)
      }

      Button('保存并连接', { type: ButtonType.Normal })
        .width('100%')
        .height(42)
        .fontColor(COLOR_BG)
        .backgroundColor(COLOR_ACCENT)
        .borderRadius(8)
        .onClick(() => {
          this.saveSettings();
        })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(COLOR_PANEL)
    .borderRadius(12)
    .border({ width: 1, color: COLOR_LINE })
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
  private MessageItem(message: ChatMessage) {
    Column({ space: 5 }) {
      Row({ space: 6 }) {
        Text(message.label)
          .fontSize(10)
          .fontColor(COLOR_MUTED)
      }
      .width('100%')
      .justifyContent(message.role === 'user' ? FlexAlign.End : FlexAlign.Start)

      Text(message.text)
        .fontSize(14)
        .lineHeight(22)
        .fontColor(COLOR_TEXT)
        .padding(12)
        .backgroundColor(message.role === 'user' ? '#23253C' : COLOR_PANEL)
        .border({ width: 1, color: message.role === 'user' ? '#363A67' : COLOR_LINE })
        .borderRadius(10)
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
        }, (message: ChatMessage) => message.id)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  @Builder
  private Composer() {
    Row({ space: 10 }) {
      TextInput({ placeholder: '输入消息', text: this.inputText })
        .fontSize(14)
        .height(42)
        .layoutWeight(1)
        .onChange((value: string) => {
          this.inputText = value;
        })
        .onSubmit(() => {
          this.sendText();
        })

      Button(this.snapshot.voiceEnabled ? '关闭' : '语音', { type: ButtonType.Normal })
        .height(42)
        .fontSize(12)
        .fontColor(this.snapshot.voiceEnabled ? COLOR_BG : COLOR_TEXT)
        .backgroundColor(this.snapshot.voiceEnabled ? COLOR_SUCCESS : COLOR_PANEL)
        .borderRadius(8)
        .onClick(() => {
          this.toggleVoice();
        })

      Button('发送', { type: ButtonType.Normal })
        .height(42)
        .fontSize(12)
        .fontColor(COLOR_BG)
        .backgroundColor(COLOR_ACCENT)
        .borderRadius(8)
        .onClick(() => {
          this.sendText();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 16 })
    .border({ width: { top: 1 }, color: COLOR_LINE })
  }

  build() {
    Column() {
      this.Header()
      if (this.showSettings) {
        this.SettingsPanel()
      } else {
        if (this.snapshot.messages.length === 0) {
          this.EmptyState()
        } else {
          this.MessageList()
        }
      }
      this.Composer()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_BG)
  }
}
