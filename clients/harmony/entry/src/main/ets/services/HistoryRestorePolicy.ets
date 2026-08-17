export class HistoryRestoreSelection {
  messages: Object[] = [];
  processComplete: boolean = false;
}

export class HistoryRestorePolicy {
  static select(resumeResult: Object, detail?: Object): HistoryRestoreSelection {
    const selection = new HistoryRestoreSelection();
    if (detail !== undefined) {
      const detailRecord = detail as Record<string, Object>;
      const detailMessages = detailRecord['messages'];
      if (Array.isArray(detailMessages)) {
        selection.messages = detailMessages as Object[];
        selection.processComplete = true;
        return selection;
      }
    }
    const resumeRecord = resumeResult as Record<string, Object>;
    const fallbackMessages = resumeRecord['messages'];
    if (Array.isArray(fallbackMessages)) {
      selection.messages = fallbackMessages as Object[];
    }
    return selection;
  }
}
