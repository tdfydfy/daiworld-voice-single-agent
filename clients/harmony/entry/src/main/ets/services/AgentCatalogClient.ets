// Dynamic Agent catalog fetched from the Native Adapter.
// Only the public identity fields are parsed on the client.

import { http } from '@kit.NetworkKit';
import { AgentInfo } from '../models/SingleAgentState';

export class AgentCatalogClient {
  async fetch(baseUrl: string, accessToken: string): Promise<AgentInfo[]> {
    const request = http.createHttp();
    const base = this.normalizeBaseUrl(baseUrl);
    try {
      const response = await request.request(base + '/api/agents', {
        method: http.RequestMethod.GET,
        header: {
          'X-Voice-Token': accessToken,
          'Accept': 'application/json'
        },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 30000
      });
      if (response.responseCode !== 200) {
        throw new Error('Agent目录 HTTP ' + String(response.responseCode));
      }
      const parsed = JSON.parse(String(response.result)) as Record<string, Object>;
      const rawAgents = parsed['agents'];
      if (!Array.isArray(rawAgents)) {
        throw new Error('Agent目录格式错误');
      }
      const agents: AgentInfo[] = [];
      for (const raw of rawAgents as Object[]) {
        const info = AgentInfo.fromObject(raw);
        if (info !== undefined && agents.find((item: AgentInfo): boolean => item.id === info.id) === undefined) {
          agents.push(info);
        }
      }
      return agents;
    } finally {
      request.destroy();
    }
  }

  private normalizeBaseUrl(baseUrl: string): string {
    const trimmed = baseUrl.trim();
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }
}
