import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { CredentialState, ProfileKey, SpeechBackend } from '../models/SingleAgentState';
import { GatewayTokenStore } from './GatewayTokenStore';

export const DEFAULT_GATEWAY_URL = 'https://voice.daiworld.cc.cd/voice-native';
const SETTINGS_FILE = 'single_agent_settings';

export interface ClientConfig {
  gatewayUrl: string;
  accessToken: string;
  profile: ProfileKey;
  muted: boolean;
  speakerphoneEnabled: boolean;
  debugMode: boolean;
  speechBackend: SpeechBackend;
  voicePerson: number;
  speechRate: number;
}

export class AppSettingsLoadResult {
  config: ClientConfig = AppSettingsStore.defaultConfig();
  credentialState: CredentialState = 'unconfigured';
  credentialError: string = '';
}

export class AppSettingsStore {
  private store?: preferences.Preferences;
  private tokenStore: GatewayTokenStore = new GatewayTokenStore();
  private persistence: Promise<void> = Promise.resolve();
  private persistedAccessToken: string = '';
  private queuedAccessToken: string = '';

  static defaultConfig(): ClientConfig {
    return {
      gatewayUrl: DEFAULT_GATEWAY_URL,
      accessToken: '',
      profile: 'default',
      muted: false,
      speakerphoneEnabled: false,
      debugMode: false,
      speechBackend: 'harmony_offline',
      voicePerson: 0,
      speechRate: 1
    };
  }

  async load(context: common.UIAbilityContext): Promise<AppSettingsLoadResult> {
    const result = new AppSettingsLoadResult();
    try {
      const store = preferences.getPreferencesSync(context, { name: SETTINGS_FILE });
      this.store = store;
      const gateway = store.getSync('gatewayUrl', DEFAULT_GATEWAY_URL);
      const profile = store.getSync('profile', 'default');
      const muted = store.getSync('muted', false);
      const speakerphoneEnabled = store.getSync('speakerphoneEnabled', false);
      const debugMode = store.getSync('debugMode', false);
      const speechBackend = store.getSync('speechBackend', 'harmony_offline');
      const voicePerson = store.getSync('voicePerson', 0);
      const speechRate = store.getSync('speechRate', 1);
      const storedTokenExists = this.tokenStore.hasStoredToken(store);
      let token = '';
      try {
        token = await this.tokenStore.load(store);
      } catch (error) {
        result.credentialState = 'storage_error';
        result.credentialError = this.credentialStorageError('读取', error as BusinessError);
      }
      if (result.credentialState !== 'storage_error') {
        result.credentialState = token.length > 0 ? 'ready' : 'unconfigured';
        result.credentialError = storedTokenExists && token.length === 0
          ? '本地存储中存在访问口令记录，但读取结果为空' : '';
      }
      result.config = this.normalize({
        gatewayUrl: typeof gateway === 'string' ? gateway : DEFAULT_GATEWAY_URL,
        accessToken: token,
        profile: this.profileFromValue(profile),
        muted: muted === true,
        speakerphoneEnabled: speakerphoneEnabled === true,
        debugMode: debugMode === true,
        speechBackend: this.speechBackendFromValue(speechBackend),
        voicePerson: typeof voicePerson === 'number' ? voicePerson : 0,
        speechRate: typeof speechRate === 'number' ? speechRate : 1
      });
      this.persistedAccessToken = token;
      this.queuedAccessToken = token;
    } catch (error) {
      this.store = undefined;
      result.credentialState = 'storage_error';
      result.credentialError = this.credentialStorageError('初始化', error as BusinessError);
    }
    return result;
  }

  normalize(config: ClientConfig): ClientConfig {
    return {
      gatewayUrl: this.normalizeGatewayUrl(config.gatewayUrl),
      accessToken: config.accessToken,
      profile: this.profileFromValue(config.profile),
      muted: config.muted,
      speakerphoneEnabled: config.speakerphoneEnabled,
      debugMode: config.debugMode,
      speechBackend: this.speechBackendFromValue(config.speechBackend),
      voicePerson: config.voicePerson,
      speechRate: this.normalizeSpeechRate(config.speechRate)
    };
  }

  persist(
    config: ClientConfig,
    onTokenSaved: (token: string) => void,
    onTokenError: () => void
  ): void {
    const store = this.store;
    if (!store) {
      return;
    }
    try {
      store.putSync('gatewayUrl', config.gatewayUrl);
      store.putSync('profile', config.profile);
      store.putSync('muted', config.muted);
      store.putSync('speakerphoneEnabled', config.speakerphoneEnabled);
      store.putSync('debugMode', config.debugMode);
      store.putSync('speechBackend', config.speechBackend);
      store.putSync('voicePerson', config.voicePerson);
      store.putSync('speechRate', config.speechRate);
      store.flushSync();
    } catch (error) {
      // Non-secret settings are a convenience; the in-memory configuration remains usable.
    }
    const token = config.accessToken;
    if (token === this.queuedAccessToken) {
      return;
    }
    this.queuedAccessToken = token;
    const operation = this.persistence.catch((): void => undefined).then((): Promise<void> =>
      this.tokenStore.saveAndVerify(store, token)
    ).then((): void => {
      this.persistedAccessToken = token;
      onTokenSaved(token);
    });
    this.persistence = operation;
    operation.catch((): void => {
      if (this.queuedAccessToken === token) {
        this.queuedAccessToken = this.persistedAccessToken;
      }
      if (this.persistence === operation) {
        this.persistence = Promise.resolve();
      }
      onTokenError();
    });
  }

  waitForPersistence(): Promise<void> {
    return this.persistence;
  }

  private profileFromValue(value: Object): ProfileKey {
    const name = String(value).trim();
    return name.length > 0 ? name : 'default';
  }

  private speechBackendFromValue(value: Object): SpeechBackend {
    return String(value) === 'remote' ? 'remote' : 'harmony_offline';
  }

  private normalizeSpeechRate(value: number): number {
    return Math.round(Math.max(0.5, Math.min(2, value)) * 10) / 10;
  }

  private normalizeGatewayUrl(value: string): string {
    const normalized = value.trim();
    if (normalized.length === 0) {
      return DEFAULT_GATEWAY_URL;
    }
    return normalized.endsWith('/') ? normalized.substring(0, normalized.length - 1) : normalized;
  }

  private credentialStorageError(stage: string, error: BusinessError): string {
    let codeValue = error && error.code !== undefined ? String(error.code) : '';
    if (codeValue.length === 0 && error && typeof error.message === 'string') {
      const matched = /code=([A-Za-z0-9_-]+)/.exec(error.message);
      codeValue = matched !== null ? matched[1] : '';
    }
    const code = codeValue.length > 0 ? '（错误码 ' + codeValue + '）' : '';
    return '访问口令本地存储' + stage + '失败' + code + '，请重新输入并保存';
  }
}
