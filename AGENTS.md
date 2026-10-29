# Meeting Recorder development

## Signing and app updates

- Build/install this Mac's app only through `bash scripts/build-app.sh`. Read README.md before changing signing.
- Reuse the existing Keychain certificate selected in `~/Library/Application Support/Meeting Recorder/signing.json`.
- Never replace it with ad-hoc signing (`codesign --sign -`), an identifier-only designated requirement, or a newly generated certificate during routine updates. These can break TCC permission persistence or weaken identity checks.
- Use `RECORDER_ALLOW_SIGNING_MIGRATION=1` only for an intentional signer transition; this requires one-time permission re-registration. Never enable it to bypass a failed routine update.
- Finish recordings and quit the main app before installation. Preserve recording data and the existing MCP executable inode for running clients.
- For signing changes run `python3 scripts/check-signing.py`, then verify a real update preserves recording access without reauthorizing.
