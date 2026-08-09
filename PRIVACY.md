# Privacy

This project is a client and gateway for AI voice conversations. A deployment may process microphone audio, speech transcripts, assistant responses, tool metadata, files, and operational logs.

Operators must document:

- which ASR, TTS, model, and storage providers receive data;
- whether raw audio is retained (the default should be no);
- transcript and artifact retention periods;
- who can access resumed sessions and downloaded artifacts;
- how users can delete their history and credentials.

Do not enable third-party summaries, diagnostics, or persistent recordings without an explicit deployment decision and user notice.
