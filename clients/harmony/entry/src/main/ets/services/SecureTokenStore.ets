import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { preferences } from '@kit.ArkData';
import { huks } from '@kit.UniversalKeystoreKit';

const KEY_ALIAS = 'daiworld.voice.access-token.v1';
const LEGACY_TOKEN_KEY = 'accessToken';
const SECURE_TOKEN_KEY = 'secureAccessTokenV1';
const ENVELOPE_VERSION = 'huks-aes-gcm-v1';
const GCM_NONCE_BYTES = 12;
const GCM_TAG_BYTES = 16;

export class SecureTokenStore {
  private base64: util.Base64Helper = new util.Base64Helper();
  private encoder: util.TextEncoder = new util.TextEncoder();
  private decoder: util.TextDecoder = new util.TextDecoder();

  async load(store: preferences.Preferences): Promise<string> {
    const encryptedValue = store.getSync(SECURE_TOKEN_KEY, '');
    if (typeof encryptedValue === 'string' && encryptedValue.length > 0) {
      const token = await this.decrypt(encryptedValue);
      this.deleteLegacyToken(store);
      return token;
    }

    const legacyValue = store.getSync(LEGACY_TOKEN_KEY, '');
    if (typeof legacyValue !== 'string' || legacyValue.length === 0) {
      return '';
    }
    await this.save(store, legacyValue);
    return legacyValue;
  }

  async save(store: preferences.Preferences, token: string): Promise<void> {
    if (token.length === 0) {
      store.deleteSync(SECURE_TOKEN_KEY);
      store.deleteSync(LEGACY_TOKEN_KEY);
      store.flushSync();
      return;
    }

    await this.ensureKey();
    const nonce = cryptoFramework.createRandom().generateRandomSync(GCM_NONCE_BYTES).data;
    const encrypted = await this.runCipher(
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT,
      nonce,
      this.encoder.encodeInto(token)
    );
    if (encrypted.length <= GCM_TAG_BYTES) {
      throw new Error('HUKS encryption returned an invalid payload');
    }
    const envelope = ENVELOPE_VERSION + ':' +
      this.base64.encodeToStringSync(nonce) + ':' +
      this.base64.encodeToStringSync(encrypted);

    store.putSync(SECURE_TOKEN_KEY, envelope);
    store.flushSync();
    this.deleteLegacyToken(store);
  }

  private deleteLegacyToken(store: preferences.Preferences): void {
    store.deleteSync(LEGACY_TOKEN_KEY);
    store.flushSync();
  }

  private async ensureKey(): Promise<void> {
    const exists = await huks.hasKeyItem(KEY_ALIAS, this.keyLookupOptions());
    if (exists) {
      return;
    }
    await huks.generateKeyItem(KEY_ALIAS, this.keyGenerationOptions());
  }

  private async decrypt(envelope: string): Promise<string> {
    const parts = envelope.split(':');
    if (parts.length !== 3 || parts[0] !== ENVELOPE_VERSION) {
      throw new Error('Unsupported secure token envelope');
    }
    const nonce = this.base64.decodeSync(parts[1]);
    const encrypted = this.base64.decodeSync(parts[2]);
    if (nonce.length !== GCM_NONCE_BYTES || encrypted.length <= GCM_TAG_BYTES) {
      throw new Error('Invalid secure token envelope');
    }
    const ciphertext = encrypted.slice(0, encrypted.length - GCM_TAG_BYTES);
    const authTag = encrypted.slice(encrypted.length - GCM_TAG_BYTES);
    const plain = await this.runCipher(
      huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT,
      nonce,
      ciphertext,
      authTag
    );
    return this.decoder.decodeToString(plain);
  }

  private async runCipher(
    purpose: huks.HuksKeyPurpose,
    nonce: Uint8Array,
    input: Uint8Array,
    authTag?: Uint8Array
  ): Promise<Uint8Array> {
    const options = this.cipherOptions(purpose, nonce, authTag);
    const session = await huks.initSession(KEY_ALIAS, options);
    try {
      const update = await huks.updateSession(session.handle, {
        properties: options.properties,
        inData: input
      }, session.challenge);
      const finish = await huks.finishSession(session.handle, {
        properties: options.properties,
        inData: new Uint8Array(0)
      }, session.challenge);
      return this.concatBytes(update.outData, finish.outData);
    } catch (error) {
      await huks.abortSession(session.handle, options).catch((): void => undefined);
      if (error instanceof Error) {
        throw error;
      }
      throw new Error('HUKS cipher operation failed');
    }
  }

  private keyLookupOptions(): huks.HuksOptions {
    return {
      properties: [{
        tag: huks.HuksTag.HUKS_TAG_AUTH_STORAGE_LEVEL,
        value: huks.HuksAuthStorageLevel.HUKS_AUTH_STORAGE_LEVEL_CE
      }]
    };
  }

  private keyGenerationOptions(): huks.HuksOptions {
    return {
      properties: [
        { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
        {
          tag: huks.HuksTag.HUKS_TAG_PURPOSE,
          value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT |
            huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT
        },
        { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
        { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
        { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
        { tag: huks.HuksTag.HUKS_TAG_NO_AUTH_REQUIRED, value: true },
        {
          tag: huks.HuksTag.HUKS_TAG_AUTH_STORAGE_LEVEL,
          value: huks.HuksAuthStorageLevel.HUKS_AUTH_STORAGE_LEVEL_CE
        }
      ]
    };
  }

  private cipherOptions(
    purpose: huks.HuksKeyPurpose,
    nonce: Uint8Array,
    authTag?: Uint8Array
  ): huks.HuksOptions {
    const properties: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce }
    ];
    if (authTag !== undefined) {
      properties.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: authTag });
    }
    return { properties: properties };
  }

  private concatBytes(first?: Uint8Array, second?: Uint8Array): Uint8Array {
    const left = first === undefined ? new Uint8Array(0) : first;
    const right = second === undefined ? new Uint8Array(0) : second;
    const joined = new Uint8Array(left.length + right.length);
    joined.set(left, 0);
    joined.set(right, left.length);
    return joined;
  }
}
