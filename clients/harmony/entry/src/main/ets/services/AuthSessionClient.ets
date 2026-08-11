// HTTP session authentication for the Single-Agent client.
// Contract source: docs/INTERACTION_AND_PORTING_SPEC.md section 3.1.
// The long-term access token is used ONCE for POST /api/auth/session and
// must never be placed into WebSocket URLs.

import { http } from '@kit.NetworkKit';

export class AuthSessionResult {
  cookie: string = '';
  error: string = '';
  statusCode: number = 0;
  unauthorized: boolean = false;
  retryable: boolean = false;
}

export class AuthSessionClient {
  private static readonly COOKIE_HEADER: string = 'Set-Cookie';

  // Returns a Cookie request header containing only the short-lived session.
  async acquireSessionCookie(baseUrl: string, accessToken: string): Promise<AuthSessionResult> {
    const result = new AuthSessionResult();
    const normalizedBaseUrl = this.normalizeBaseUrl(baseUrl);
    const request = http.createHttp();
    try {
      const response = await request.request(
        normalizedBaseUrl + '/api/auth/session',
        {
          method: http.RequestMethod.POST,
          header: {
            'X-Voice-Token': accessToken,
            'Content-Type': 'application/json'
          },
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 15000,
          readTimeout: 15000
        }
      );
      result.statusCode = response.responseCode;
      if (response.responseCode !== 200) {
        result.unauthorized = response.responseCode === 401 || response.responseCode === 403;
        result.retryable = response.responseCode >= 500;
        result.error = result.unauthorized
          ? '访问口令错误，请填写服务器的 VOICE_ACCESS_TOKEN'
          : '网关返回 HTTP ' + String(response.responseCode);
        return result;
      }
      result.cookie = this.extractSessionCookie(response.header);
      if (result.cookie.length === 0) {
        result.error = '网关未返回登录会话';
      }
      return result;
    } catch (error) {
      result.error = '无法连接网关';
      result.retryable = true;
      return result;
    } finally {
      request.destroy();
    }
  }

  private normalizeBaseUrl(baseUrl: string): string {
    const trimmed = baseUrl.trim();
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }

  private extractSessionCookie(header: Object): string {
    const headers = header as Record<string, Object>;
    for (const key of Object.keys(headers)) {
      if (key.toLowerCase() !== AuthSessionClient.COOKIE_HEADER.toLowerCase()) {
        continue;
      }
      const rawString = String(headers[key]);
      const match = rawString.match(/(?:^|[,\r\n\s])voice_session=([^;,\s]+)/i);
      if (match && match.length > 1) {
        return 'voice_session=' + match[1];
      }
    }
    return '';
  }
}
