import {
  ModelOptionInfo,
  ModelProviderInfo,
  SingleAgentSnapshot
} from '../models/SingleAgentState';
import { ModelOptionsCatalog } from './ModelOptionsClient';

export class RuntimeIdentitySync {
  private lastCatalog?: ModelOptionsCatalog;

  resetCatalog(): void {
    this.lastCatalog = undefined;
  }

  applySessionInfo(data: Record<string, Object> | undefined, snapshot: SingleAgentSnapshot): boolean {
    if (data === undefined) {
      return false;
    }
    if (data['model'] !== undefined) {
      snapshot.runtimeModel = String(data['model']).trim();
    }
    snapshot.runtimeProvider = this.providerDisplay(data);
    if (this.lastCatalog !== undefined) {
      this.reconcileCatalog(this.lastCatalog, snapshot);
    }
    return this.isGenericProvider(snapshot.runtimeProvider);
  }

  reconcileCatalog(catalog: ModelOptionsCatalog, snapshot: SingleAgentSnapshot): void {
    this.lastCatalog = catalog;
    if (!this.isGenericProvider(snapshot.runtimeProvider)) {
      return;
    }
    let providerLabel = catalog.activeProviderLabel.trim();
    if (providerLabel.length === 0 && snapshot.runtimeModel.length > 0) {
      const candidates = catalog.providers.filter((provider: ModelProviderInfo): boolean =>
        provider.models.find((model: ModelOptionInfo): boolean =>
          model.id === snapshot.runtimeModel) !== undefined);
      if (candidates.length === 1) {
        providerLabel = candidates[0].name;
      }
    }
    if (providerLabel.length === 0 || this.isGenericProvider(providerLabel)) {
      return;
    }
    snapshot.runtimeProvider = providerLabel;
    for (const message of snapshot.messages) {
      if (message.role === 'assistant' && this.isGenericProvider(message.provider)) {
        message.provider = providerLabel;
        message.revision += 1;
      }
    }
  }

  providerDisplay(data: Record<string, Object> | undefined): string {
    if (data === undefined) {
      return '';
    }
    for (const key of ['provider_label', 'provider_name', 'runtime_provider_label', 'runtime_provider']) {
      if (data[key] !== undefined) {
        const value = String(data[key]).trim();
        if (value.length > 0) {
          return value;
        }
      }
    }
    return data['provider'] !== undefined ? String(data['provider']).trim() : '';
  }

  isGenericProvider(value: string): boolean {
    const normalized = value.trim().toLowerCase().replace(/[^a-z0-9]/g, '');
    return normalized.length === 0 || normalized === 'custom' || normalized === 'openaiapi' ||
      normalized === 'openaicompatible' || normalized === 'openaicompatibleapi';
  }
}
