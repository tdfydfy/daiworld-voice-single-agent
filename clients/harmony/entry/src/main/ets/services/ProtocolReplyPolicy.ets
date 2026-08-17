export type ApprovalDecision = 'none' | 'allow' | 'deny';

const APPROVAL_ALLOW_PHRASES: string[] = ['同意'];
const APPROVAL_DENY_PHRASES: string[] = ['取消'];

export class ProtocolReplyPolicy {
  static approvalDecision(text: string): ApprovalDecision {
    const normalized = ProtocolReplyPolicy.normalizeApproval(text);
    if (APPROVAL_ALLOW_PHRASES.includes(normalized)) {
      return 'allow';
    }
    if (APPROVAL_DENY_PHRASES.includes(normalized)) {
      return 'deny';
    }
    return 'none';
  }

  static clarifyAnswer(text: string, choices: string[]): string {
    const value = text.trim();
    const normalized = ProtocolReplyPolicy.normalizeChoice(value);
    if (normalized.length === 0 || choices.length === 0) {
      return value;
    }
    for (const choice of choices) {
      if (ProtocolReplyPolicy.normalizeChoice(choice) === normalized) {
        return choice;
      }
    }
    return value;
  }

  private static normalizeApproval(text: string): string {
    return text.trim().toLowerCase().replace(/\s/gu, '')
      .replace(/^[\p{P}\p{S}]+/gu, '')
      .replace(/[\p{P}\p{S}]+$/gu, '');
  }

  private static normalizeChoice(text: string): string {
    return text.trim().toLowerCase().replace(/[\s\p{P}\p{S}]/gu, '');
  }
}
