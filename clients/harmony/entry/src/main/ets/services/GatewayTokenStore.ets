import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LEGACY_TOKEN_KEY = 'accessToken';
const SECURE_TOKEN_KEY = 'secureAccessTokenV1';
const TOKEN_LOG_DOMAIN = 0xD004;
const TOKEN_LOG_TAG = 'GatewayTokenStore';

/**
 * The current device baseline uses Preferences for the gateway token. The
 * previous HUKS envelope is retired because it fails to round-trip reliably
 * on the target HarmonyOS build and must not block the connection workflow.
 */
export class GatewayTokenStore {
  async load(store: preferences.Preferences): Promise<string> {
    const token = store.getSync(LEGACY_TOKEN_KEY, '');
    const retiredSecureValue = store.getSync(SECURE_TOKEN_KEY, '');
    if (typeof retiredSecureValue === 'string' && retiredSecureValue.length > 0) {
      store.deleteSync(SECURE_TOKEN_KEY);
      store.flushSync();
      hilog.info(TOKEN_LOG_DOMAIN, TOKEN_LOG_TAG, 'retired token record cleared');
    }
    hilog.info(
      TOKEN_LOG_DOMAIN,
      TOKEN_LOG_TAG,
      'token load record=%{public}s',
      typeof token === 'string' && token.length > 0 ? 'present' : 'absent'
    );
    return typeof token === 'string' ? token : '';
  }

  hasStoredToken(store: preferences.Preferences): boolean {
    const token = store.getSync(LEGACY_TOKEN_KEY, '');
    return typeof token === 'string' && token.length > 0;
  }

  async saveAndVerify(store: preferences.Preferences, token: string): Promise<void> {
    await this.save(store, token);
    const restored = store.getSync(LEGACY_TOKEN_KEY, '');
    if (typeof restored !== 'string' || restored !== token) {
      throw new Error('Gateway token persistence verification failed');
    }
    hilog.info(TOKEN_LOG_DOMAIN, TOKEN_LOG_TAG, 'token save stage=%{public}s', 'complete');
  }

  async save(store: preferences.Preferences, token: string): Promise<void> {
    if (token.length === 0) {
      store.deleteSync(LEGACY_TOKEN_KEY);
    } else {
      store.putSync(LEGACY_TOKEN_KEY, token);
    }
    store.deleteSync(SECURE_TOKEN_KEY);
    store.flushSync();
    hilog.info(
      TOKEN_LOG_DOMAIN,
      TOKEN_LOG_TAG,
      'token save record=%{public}s',
      token.length > 0 ? 'present' : 'absent'
    );
  }
}
