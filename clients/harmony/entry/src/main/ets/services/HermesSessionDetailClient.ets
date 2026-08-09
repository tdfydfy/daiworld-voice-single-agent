import { http } from '@kit.NetworkKit';

export class HermesSessionDetailClient {
  async fetch(
    baseUrl: string,
    accessToken: string,
    profile: string,
    sessionId: string
  ): Promise<Object> {
    const request = http.createHttp();
    const base = this.normalizeBaseUrl(baseUrl);
    const url = base + '/api/hermes/sessions/' + encodeURIComponent(sessionId) +
      '?profile=' + encodeURIComponent(profile);
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
        throw new Error('history detail HTTP ' + String(response.responseCode));
      }
      return JSON.parse(String(response.result)) as Object;
    } finally {
      request.destroy();
    }
  }

  private normalizeBaseUrl(baseUrl: string): string {
    const trimmed = baseUrl.trim();
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }
}
