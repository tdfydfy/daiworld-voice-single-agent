// Keeps local stop feedback separate from unverified Hermes task state.
export class StopTaskState {
  private currentRequestGeneration: number = 0;

  beginRequest(): number {
    this.currentRequestGeneration += 1;
    return this.currentRequestGeneration;
  }

  invalidatePendingRequest(): void {
    this.currentRequestGeneration += 1;
  }

  isCurrentRequest(generation: number): boolean {
    return this.currentRequestGeneration === generation;
  }

  static localStoppedPendingConfirmation(): string {
    return '本地已停止，任务/队列状态待确认';
  }

  static requestConfirmedPendingConfirmation(): string {
    return '停止请求已确认，任务/队列状态待确认';
  }

  static requestFailedPendingConfirmation(): string {
    return '本地已停止，停止请求失败，任务/队列状态待确认';
  }
}
