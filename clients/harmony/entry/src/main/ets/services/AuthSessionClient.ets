// HTTP session authentication for the Single-Agent client.
// Contract source: docs/INTERACTION_AND_PORTING_SPEC.md section 3.1.
// The long-term access token is used ONCE for POST /api/auth/session and
// must never be placed into WebSocket URLs.

import { http } from '@kit.NetworkKit';

export class AuthSessionClient {
  private static readonly COOKIE_HEADER: string = 'Set-Cookie';
  private static readonly SESSION_COOKIE_PREFIX: string = 'voice_session=';

  // Returns the voice_session cookie value (without attribute flags), or ''.
  async acquireSessionCookie(baseUrl: string, accessToken: string): Promise<string> {
    const request = http.createHttp();
    try {
      const response = await request.request(
        baseUrl + '/api/auth/session',
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
      if (response.responseCode !== 200) {
        return '';
      }
      return this.extractSessionCookie(response.header);
    } catch (error) {
      return '';
    } finally {
      request.destroy();
    }
  }

  private extractSessionCookie(header: Object): string {
    const headers = header as Record<string, Object>;
    const raw = headers[AuthSessionClient.COOKIE_HEADER];
    if (raw === undefined) {
      return '';
    }
    const rawString = String(raw);
    const entries = rawString.split('\n');
    for (const entry of entries) {
      const trimmed = entry.trim();
      if (trimmed.startsWith(AuthSessionClient.SESSION_COOKIE_PREFIX)) {
        const firstSemicolon = trimmed.indexOf(';');
        if (firstSemicolon === -1) {
          return trimmed.substring(AuthSessionClient.SESSION_COOKIE_PREFIX.length);
        }
        return trimmed.substring(
          AuthSessionClient.SESSION_COOKIE_PREFIX.length,
          firstSemicolon
        );
      }
    }
    return '';
  }
}
