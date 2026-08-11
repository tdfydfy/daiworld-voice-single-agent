// Available Hermes model/provider choices fetched through the Native Adapter.
// The client receives public identifiers only; provider credentials stay upstream.

import { http } from '@kit.NetworkKit';
import { ModelProviderInfo } from '../models/SingleAgentState';

export class ModelOptionsCatalog {
  providers: ModelProviderInfo[] = [];
  activeProviderLabel: string = '';
}

export class ModelOptionsClient {
  async fetch(baseUrl: string, accessToken: string, profile: string): Promise<ModelOptionsCatalog> {
    const request = http.createHttp();
    const base = this.normalizeBaseUrl(baseUrl);
    const url = base + '/api/hermes/model/options?profile=' + encodeURIComponent(profile);
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'X-Voice-Token': accessToken,
          'Accept': 'application/json'
        },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 60000
      });
      if (response.responseCode !== 200) {
        throw new Error('模型列表 HTTP ' + String(response.responseCode));
      }
      const parsed = JSON.parse(String(response.result)) as Record<string, Object>;
      const rawProviders = parsed['providers'];
      if (!Array.isArray(rawProviders)) {
        throw new Error('模型列表格式错误');
      }
      const providers: ModelProviderInfo[] = [];
      for (const rawProvider of rawProviders as Object[]) {
        const provider = ModelProviderInfo.fromObject(rawProvider);
        if (provider !== undefined && providers.find(
          (item: ModelProviderInfo): boolean => item.id === provider.id
        ) === undefined) {
          providers.push(provider);
        }
      }
      const catalog = new ModelOptionsCatalog();
      catalog.providers = providers;
      const activeProviderLabel = parsed['active_provider_label'];
      catalog.activeProviderLabel = typeof activeProviderLabel === 'string'
        ? activeProviderLabel.trim() : '';
      return catalog;
    } finally {
      request.destroy();
    }
  }

  private normalizeBaseUrl(baseUrl: string): string {
    const trimmed = baseUrl.trim();
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }
}
