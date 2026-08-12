import { BusinessError } from '@kit.BasicServicesKit';
import {
  AgentCatalog,
  ModelOptionInfo,
  ModelProviderInfo,
  SingleAgentSnapshot
} from '../models/SingleAgentState';
import { AgentCatalogClient } from './AgentCatalogClient';
import { AuthSessionClient, AuthSessionResult } from './AuthSessionClient';
import { GatewayListener, HermesGatewayClient } from './HermesGatewayClient';
import { HermesSessionDetailClient } from './HermesSessionDetailClient';
import { ModelOptionsCatalog, ModelOptionsClient } from './ModelOptionsClient';
import { RuntimeIdentitySync } from './RuntimeIdentitySync';

const GATEWAY_RECONNECT_DELAYS_MS: number[] = [500, 1500, 3000, 5000];
const GATEWAY_RECONNECT_MAX_ATTEMPTS = 6;
const GATEWAY_READY_TIMEOUT_MS = 10000;
const MODEL_SWITCH_CONFIRM_TIMEOUT_MS = 10000;

export class HermesRuntimeCallbacks {
  private changedCallback: () => void;
  private profileSelectedCallback: (profile: string) => void;
  private readyCallback: () => void;
  private eventCallback: (type: string, sessionId: string, payload: Object | undefined) => void;
  private unavailableCallback: (message: string, wasOnline: boolean) => void;

  constructor(
    changedCallback: () => void,
    profileSelectedCallback: (profile: string) => void,
    readyCallback: () => void,
    eventCallback: (type: string, sessionId: string, payload: Object | undefined) => void,
    unavailableCallback: (message: string, wasOnline: boolean) => void
  ) {
    this.changedCallback = changedCallback;
    this.profileSelectedCallback = profileSelectedCallback;
    this.readyCallback = readyCallback;
    this.eventCallback = eventCallback;
    this.unavailableCallback = unavailableCallback;
  }

  changed(): void {
    this.changedCallback();
  }

  profileSelected(profile: string): void {
    this.profileSelectedCallback(profile);
  }

  ready(): void {
    this.readyCallback();
  }

  event(type: string, sessionId: string, payload: Object | undefined): void {
    this.eventCallback(type, sessionId, payload);
  }

  unavailable(message: string, wasOnline: boolean): void {
    this.unavailableCallback(message, wasOnline);
  }
}

// Owns Hermes authentication, catalog/model state, gateway connection recovery,
// and the low-level JSON-RPC client. Cross-domain conversation and voice policy
// stays in SingleAgentController through the narrow callbacks above.
export class HermesRuntime extends GatewayListener {
  private snapshot: SingleAgentSnapshot;
  private callbacks: HermesRuntimeCallbacks;
  private gateway: HermesGatewayClient = new HermesGatewayClient();
  private auth: AuthSessionClient = new AuthSessionClient();
  private agentCatalogClient: AgentCatalogClient = new AgentCatalogClient();
  private modelOptionsClient: ModelOptionsClient = new ModelOptionsClient();
  private sessionDetailClient: HermesSessionDetailClient = new HermesSessionDetailClient();
  private identity: RuntimeIdentitySync = new RuntimeIdentitySync();
  private agentCatalog: AgentCatalog = new AgentCatalog();
  private cookie: string = '';
  private baseUrl: string = '';
  private accessToken: string = '';
  private profile: string = '';
  private modelSwitchTimeout?: number;
  private modelSwitchSequence: number = 0;
  private modelOptionsSequence: number = 0;
  private requestedModelProvider: string = '';
  private requestedModel: string = '';
  private modelBeforeSwitch: string = '';
  private gatewayReconnectTimer?: number;
  private gatewayReconnectAttempt: number = 0;
  private gatewayReconnectInFlight: boolean = false;
  private gatewayReconnectBlocked: boolean = false;
  private gatewayConnectGeneration: number = 0;
  private gatewayReadyTimeout?: number;

  constructor(snapshot: SingleAgentSnapshot, callbacks: HermesRuntimeCallbacks) {
    super();
    this.snapshot = snapshot;
    this.callbacks = callbacks;
    this.gateway.setListener(this);
  }

  async connect(baseUrl: string, accessToken: string, profile: string): Promise<void> {
    if (this.snapshot.connection === 'connecting' || this.snapshot.connection === 'online') {
      return;
    }
    this.baseUrl = baseUrl;
    this.accessToken = accessToken;
    this.profile = profile;
    this.cancelGatewayReconnect();
    this.gatewayReconnectBlocked = false;
    const generation = ++this.gatewayConnectGeneration;
    await this.connectGateway(false, generation);
  }

  disconnect(): void {
    this.gatewayReconnectBlocked = true;
    this.gatewayConnectGeneration += 1;
    this.cancelGatewayReconnect();
    this.clearGatewayReadyTimeout();
    this.cancelModelSwitch('');
    this.gateway.close();
    this.snapshot.connection = 'offline';
  }

  getCookie(): string {
    return this.cookie;
  }

  agentDisplayName(id: string): string {
    return this.agentCatalog.displayName(id);
  }

  loadModelOptions(baseUrl: string, accessToken: string, profile: string): void {
    if (this.snapshot.modelOptionsLoading) {
      return;
    }
    if (accessToken.length === 0) {
      this.snapshot.modelProviders = [];
      this.snapshot.modelOptionsError = '请先保存访问口令';
      this.callbacks.changed();
      return;
    }
    this.snapshot.modelOptionsLoading = true;
    this.snapshot.modelProviders = [];
    this.snapshot.modelOptionsError = '';
    const sequence = ++this.modelOptionsSequence;
    this.callbacks.changed();
    this.modelOptionsClient.fetch(baseUrl, accessToken, profile).then((catalog: ModelOptionsCatalog): void => {
      if (sequence !== this.modelOptionsSequence || profile !== this.snapshot.selectedProfile) {
        return;
      }
      const providers = catalog.providers;
      this.snapshot.modelProviders = providers;
      this.snapshot.modelOptionsLoading = false;
      this.snapshot.modelOptionsError = providers.length > 0 ? '' : '服务器暂未返回可用模型';
      this.identity.reconcileCatalog(catalog, this.snapshot);
      this.callbacks.changed();
    }).catch((error: BusinessError): void => {
      if (sequence !== this.modelOptionsSequence || profile !== this.snapshot.selectedProfile) {
        return;
      }
      this.snapshot.modelProviders = [];
      this.snapshot.modelOptionsLoading = false;
      this.snapshot.modelOptionsError = this.errorMessage(error, '模型列表加载失败');
      this.callbacks.changed();
    });
  }

  switchRuntimeModel(providerId: string, modelId: string): void {
    if (this.snapshot.modelSwitching) {
      return;
    }
    if (this.snapshot.connection !== 'online' || this.snapshot.runtimeSessionId.length === 0) {
      this.snapshot.modelSwitchError = '当前会话尚未连接';
      this.callbacks.changed();
      return;
    }
    if (this.snapshot.agentBusy) {
      this.snapshot.modelSwitchError = '请等待当前任务结束后再切换模型';
      this.callbacks.changed();
      return;
    }
    const provider = this.snapshot.modelProviders.find(
      (item: ModelProviderInfo): boolean => item.id === providerId
    );
    const model = provider?.models.find((item: ModelOptionInfo): boolean => item.id === modelId);
    if (provider === undefined || model === undefined ||
      !this.isSafeConfigAtom(provider.id) || !this.isSafeConfigAtom(model.id)) {
      this.snapshot.modelSwitchError = '请选择有效的 Provider 和模型';
      this.callbacks.changed();
      return;
    }
    this.clearModelSwitchTimeout();
    const sequence = ++this.modelSwitchSequence;
    this.requestedModelProvider = provider.id;
    this.requestedModel = model.id;
    this.modelBeforeSwitch = this.snapshot.runtimeModel;
    this.snapshot.modelSwitching = true;
    this.snapshot.modelSwitchStatus = '正在提交当前会话配置';
    this.snapshot.modelSwitchError = '';
    this.callbacks.changed();
    this.modelSwitchTimeout = setTimeout((): void => {
      this.modelSwitchTimeout = undefined;
      if (sequence !== this.modelSwitchSequence || !this.snapshot.modelSwitching) {
        return;
      }
      this.snapshot.modelSwitching = false;
      this.snapshot.modelSwitchStatus = '';
      this.snapshot.modelSwitchError = 'Hermes 未返回 session.info，仍显示上次已确认的运行配置';
      this.resetRequestedModel();
      this.callbacks.changed();
    }, MODEL_SWITCH_CONFIRM_TIMEOUT_MS);
    const value = model.id + ' --provider ' + provider.id + ' --session';
    this.gateway.setConfig('model', value).then((): void => {
      if (sequence !== this.modelSwitchSequence || !this.snapshot.modelSwitching) {
        return;
      }
      this.snapshot.modelSwitchStatus = '切换请求已提交，等待 Hermes 确认';
      this.callbacks.changed();
    }).catch((error: BusinessError): void => {
      if (sequence !== this.modelSwitchSequence || !this.snapshot.modelSwitching) {
        return;
      }
      this.clearModelSwitchTimeout();
      this.snapshot.modelSwitching = false;
      this.snapshot.modelSwitchStatus = '';
      this.snapshot.modelSwitchError = this.errorMessage(error, '模型切换失败');
      this.resetRequestedModel();
      this.callbacks.changed();
    });
  }

  syncRuntimeIdentity(
    data: Record<string, Object> | undefined,
    baseUrl: string,
    accessToken: string,
    profile: string
  ): void {
    this.identity.applySessionInfo(data, this.snapshot);
    this.confirmModelSwitch(data);
    if (!this.snapshot.modelOptionsLoading && this.snapshot.modelProviders.length === 0) {
      this.loadModelOptions(baseUrl, accessToken, profile);
    }
  }

  providerDisplay(data: Record<string, Object> | undefined): string {
    return this.identity.providerDisplay(data);
  }

  private clearModelOptions(): void {
    this.modelOptionsSequence += 1;
    this.snapshot.modelProviders = [];
    this.snapshot.modelOptionsLoading = false;
    this.snapshot.modelOptionsError = '';
  }

  resetModelSelection(): void {
    this.clearModelOptions();
    this.identity.resetCatalog();
    this.cancelModelSwitch('');
    this.snapshot.runtimeModel = '';
    this.snapshot.runtimeProvider = '';
    this.snapshot.modelSwitchStatus = '';
    this.snapshot.modelSwitchError = '';
  }

  private cancelModelSwitch(message: string): void {
    if (!this.snapshot.modelSwitching) {
      return;
    }
    this.modelSwitchSequence += 1;
    this.clearModelSwitchTimeout();
    this.snapshot.modelSwitching = false;
    this.snapshot.modelSwitchStatus = '';
    this.snapshot.modelSwitchError = message;
    this.resetRequestedModel();
  }

  fetchSessionDetail(
    baseUrl: string,
    accessToken: string,
    profile: string,
    sessionId: string
  ): Promise<Object> {
    return this.sessionDetailClient.fetch(baseUrl, accessToken, profile, sessionId);
  }

  createSession(cols: number): Promise<Object> {
    return this.gateway.createSession(cols);
  }

  listSessions(limit: number): Promise<Object> {
    return this.gateway.listSessions(limit);
  }

  resumeSession(storedId: string, cols: number): Promise<Object> {
    return this.gateway.resumeSession(storedId, cols);
  }

  deleteSession(storedId: string): Promise<Object> {
    return this.gateway.deleteSession(storedId);
  }

  submitPrompt(text: string, queued: boolean): Promise<Object> {
    return this.gateway.submitPrompt(text, queued);
  }

  interrupt(): Promise<Object> {
    return this.gateway.interrupt();
  }

  respondApproval(choice: string): Promise<Object> {
    return this.gateway.respondApproval(choice);
  }

  respondClarify(requestId: string, answer: string): Promise<Object> {
    return this.gateway.respondClarify(requestId, answer);
  }

  onGatewayReady(): void {
    this.clearGatewayReadyTimeout();
    this.gatewayReconnectInFlight = false;
    this.gatewayReconnectAttempt = 0;
    this.gatewayReconnectBlocked = false;
    this.snapshot.connection = 'online';
    this.snapshot.error = '';
    this.callbacks.ready();
    this.callbacks.changed();
  }

  onEvent(type: string, sessionId: string, payload: Object | undefined): void {
    this.callbacks.event(type, sessionId, payload);
  }

  onError(message: string): void {
    this.clearGatewayReadyTimeout();
    const errorText = typeof message === 'string' && message.length > 0 ? message : '网关连接失败';
    this.snapshot.connection = 'offline';
    this.snapshot.error = errorText;
    this.cancelModelSwitch('模型切换未确认：' + errorText);
    this.callbacks.unavailable(errorText, true);
    this.scheduleGatewayReconnect(errorText);
    this.callbacks.changed();
  }

  onClosed(): void {
    this.clearGatewayReadyTimeout();
    const wasOnline = this.snapshot.connection === 'online';
    this.snapshot.connection = 'offline';
    if (wasOnline) {
      this.snapshot.error = '网关连接已断开';
      this.cancelModelSwitch('模型切换未确认：网关连接已断开');
    }
    this.callbacks.unavailable('网关连接已断开', wasOnline);
    this.scheduleGatewayReconnect('网关连接已断开');
    this.callbacks.changed();
  }

  private async connectGateway(reconnecting: boolean, generation: number): Promise<void> {
    if (this.snapshot.connection === 'online' ||
      (!reconnecting && this.snapshot.connection === 'connecting')) {
      return;
    }
    this.snapshot.connection = 'connecting';
    this.snapshot.statusTitle = reconnecting ? '正在恢复连接' : '正在连接';
    this.snapshot.error = '';
    this.snapshot.agentsLoading = true;
    this.snapshot.agentsError = '';
    this.callbacks.changed();
    try {
      const authResult = await this.authenticate();
      if (!this.isActiveConnection(generation)) {
        this.gatewayReconnectInFlight = false;
        return;
      }
      if (authResult.cookie.length === 0) {
        this.gatewayReconnectInFlight = false;
        this.snapshot.connection = 'offline';
        this.snapshot.agentsLoading = false;
        this.snapshot.error = authResult.error.length > 0
          ? authResult.error : '鉴权失败，请检查网关地址和访问口令';
        if (authResult.unauthorized) {
          this.gatewayReconnectBlocked = true;
          this.snapshot.credentialState = 'unauthorized';
          this.snapshot.credentialError = '已保存的访问口令未通过服务器验证';
        } else if (authResult.retryable) {
          this.scheduleGatewayReconnect(this.snapshot.error);
        }
        this.callbacks.changed();
        return;
      }
      this.snapshot.credentialState = 'ready';
      this.snapshot.credentialError = '';
      if (!await this.loadAgentCatalog(generation)) {
        this.gatewayReconnectInFlight = false;
        if (this.snapshot.agentsError.length > 0) {
          this.scheduleGatewayReconnect(this.snapshot.error);
          this.callbacks.changed();
        }
        return;
      }
      if (!this.isActiveConnection(generation)) {
        this.gatewayReconnectInFlight = false;
        return;
      }
      this.openGateway();
      this.gatewayReconnectInFlight = false;
    } catch (error) {
      this.snapshot.connection = 'offline';
      this.snapshot.error = '连接失败';
      this.snapshot.agentsLoading = false;
      this.gatewayReconnectInFlight = false;
      this.scheduleGatewayReconnect(this.snapshot.error);
      this.callbacks.changed();
    }
  }

  private async authenticate(): Promise<AuthSessionResult> {
    const result = await this.auth.acquireSessionCookie(this.baseUrl, this.accessToken);
    if (result.cookie.length > 0) {
      this.cookie = result.cookie;
    }
    return result;
  }

  private async loadAgentCatalog(generation: number): Promise<boolean> {
    try {
      const agents = await this.agentCatalogClient.fetch(this.baseUrl, this.accessToken);
      if (!this.isActiveConnection(generation)) {
        return false;
      }
      this.agentCatalog.agents = agents;
      this.snapshot.agents = agents.slice();
      this.snapshot.agentsLoading = false;
      this.snapshot.agentsError = '';
      const selected = this.agentCatalog.find(this.profile);
      const fallback = this.agentCatalog.fallback();
      if (selected === undefined && fallback !== undefined) {
        this.resetModelSelection();
        this.profile = fallback.id;
        this.snapshot.selectedProfile = fallback.id;
        this.callbacks.profileSelected(fallback.id);
      }
      if (fallback === undefined) {
        this.snapshot.connection = 'offline';
        this.snapshot.error = '服务器暂未配置可用 Agent';
        this.snapshot.statusTitle = '无可用 Agent';
        this.snapshot.statusDetail = '';
        this.callbacks.changed();
        return false;
      }
      this.snapshot.error = '';
      this.callbacks.changed();
      return true;
    } catch (error) {
      if (!this.isActiveConnection(generation)) {
        return false;
      }
      this.snapshot.agentsLoading = false;
      this.snapshot.agentsError = 'Agent目录加载失败';
      this.snapshot.connection = 'offline';
      this.snapshot.error = this.errorMessage(error as BusinessError, 'Agent目录加载失败');
      this.callbacks.changed();
      return false;
    }
  }

  private openGateway(): void {
    this.gateway.connect(this.wsUrl('/api/hermes/ws', this.profile), this.cookie);
    this.clearGatewayReadyTimeout();
    this.gatewayReadyTimeout = setTimeout((): void => {
      this.gatewayReadyTimeout = undefined;
      if (this.snapshot.connection !== 'connecting') {
        return;
      }
      this.gateway.close();
      this.snapshot.connection = 'offline';
      this.scheduleGatewayReconnect('网关连接超时');
      this.callbacks.changed();
    }, GATEWAY_READY_TIMEOUT_MS);
  }

  private scheduleGatewayReconnect(reason: string): void {
    if (this.gatewayReconnectBlocked || this.accessToken.length === 0 ||
      this.gatewayReconnectTimer !== undefined || this.gatewayReconnectInFlight ||
      this.snapshot.connection === 'online') {
      return;
    }
    if (this.gatewayReconnectAttempt >= GATEWAY_RECONNECT_MAX_ATTEMPTS) {
      this.gatewayReconnectBlocked = true;
      this.snapshot.connection = 'offline';
      this.snapshot.statusTitle = '连接已停止恢复';
      this.snapshot.statusDetail = '请检查网络或重新保存访问口令';
      this.snapshot.error = reason;
      return;
    }
    const index = Math.min(this.gatewayReconnectAttempt, GATEWAY_RECONNECT_DELAYS_MS.length - 1);
    const delay = GATEWAY_RECONNECT_DELAYS_MS[index];
    this.gatewayReconnectAttempt += 1;
    this.snapshot.connection = 'connecting';
    this.snapshot.statusTitle = '正在恢复连接';
    this.snapshot.statusDetail = '将在 ' + String(delay) + ' ms 后重试';
    this.snapshot.error = '';
    this.gatewayReconnectTimer = setTimeout((): void => {
      this.gatewayReconnectTimer = undefined;
      if (this.gatewayReconnectBlocked || this.snapshot.connection === 'online') {
        return;
      }
      this.gatewayReconnectInFlight = true;
      const generation = ++this.gatewayConnectGeneration;
      this.connectGateway(true, generation).then((): void => {
        this.gatewayReconnectInFlight = false;
      }).catch((): void => {
        this.gatewayReconnectInFlight = false;
      });
    }, delay);
  }

  private cancelGatewayReconnect(): void {
    if (this.gatewayReconnectTimer !== undefined) {
      clearTimeout(this.gatewayReconnectTimer);
      this.gatewayReconnectTimer = undefined;
    }
    this.gatewayReconnectAttempt = 0;
    this.gatewayReconnectInFlight = false;
  }

  private clearGatewayReadyTimeout(): void {
    if (this.gatewayReadyTimeout !== undefined) {
      clearTimeout(this.gatewayReadyTimeout);
      this.gatewayReadyTimeout = undefined;
    }
  }

  private clearModelSwitchTimeout(): void {
    if (this.modelSwitchTimeout !== undefined) {
      clearTimeout(this.modelSwitchTimeout);
      this.modelSwitchTimeout = undefined;
    }
  }

  private resetRequestedModel(): void {
    this.requestedModelProvider = '';
    this.requestedModel = '';
    this.modelBeforeSwitch = '';
  }

  private confirmModelSwitch(data: Record<string, Object> | undefined): void {
    if (!this.snapshot.modelSwitching || data === undefined || this.requestedModel.length === 0) {
      return;
    }
    const confirmedModel = data['model'] !== undefined ? String(data['model']).trim() : '';
    if (confirmedModel !== this.requestedModel) {
      return;
    }
    if (this.requestedModel === this.modelBeforeSwitch) {
      const rawProvider = data['provider'] !== undefined ? String(data['provider']).trim() : '';
      const displayProvider = this.identity.providerDisplay(data);
      const option = this.snapshot.modelProviders.find(
        (item: ModelProviderInfo): boolean => item.id === this.requestedModelProvider
      );
      const providerName = option !== undefined ? option.name : '';
      if (rawProvider !== this.requestedModelProvider &&
        displayProvider !== this.requestedModelProvider &&
        (providerName.length === 0 || displayProvider !== providerName)) {
        return;
      }
    }
    const confirmedProvider = this.snapshot.modelProviders.find(
      (item: ModelProviderInfo): boolean => item.id === this.requestedModelProvider
    );
    if (confirmedProvider !== undefined) {
      this.snapshot.runtimeProvider = confirmedProvider.name;
    }
    this.clearModelSwitchTimeout();
    this.snapshot.modelSwitching = false;
    this.snapshot.modelSwitchError = '';
    const identity = [this.snapshot.runtimeProvider, this.snapshot.runtimeModel]
      .filter((value: string): boolean => value.length > 0).join(' · ');
    this.snapshot.modelSwitchStatus = identity.length > 0
      ? '当前会话已确认：' + identity : '当前会话模型已确认';
    this.resetRequestedModel();
  }

  private isActiveConnection(generation: number): boolean {
    return generation === this.gatewayConnectGeneration && !this.gatewayReconnectBlocked;
  }

  private isSafeConfigAtom(value: string): boolean {
    return value.length > 0 && !/\s/.test(value) && !value.startsWith('--');
  }

  private errorMessage(error: BusinessError, fallback: string): string {
    return error && typeof error.message === 'string' && error.message.length > 0
      ? error.message : fallback;
  }

  private wsUrl(path: string, profile: string): string {
    const trimmed = this.baseUrl.endsWith('/')
      ? this.baseUrl.substring(0, this.baseUrl.length - 1) : this.baseUrl;
    const scheme = trimmed.startsWith('https:') ? 'wss:' : 'ws:';
    const rest = trimmed.startsWith('http') ? trimmed.substring(trimmed.indexOf('//')) : trimmed;
    return scheme + rest + path + '?profile=' + encodeURIComponent(profile);
  }
}
