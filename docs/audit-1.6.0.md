# Bigroute 1.6.0 audit — 2026-09-06

Status: source upgrade prepared; **release held**. The reported phone Remote Control failure has not been fixed. Passing proxy tests must not be presented as a successful phone test.

## Findings and changes

| Area | Observed problem | Implemented change |
| --- | --- | --- |
| Bridge forwarding | Buffered/unbounded forwarding, stale connection headers, incomplete cancellation, and ambiguous behavior after truncated responses | Stream unknown RPCs, remove hop-by-hop headers, propagate cancellation/backpressure, enforce idle deadlines and bounded transformed bodies, fail interrupted replies |
| Generation conversion | Split UTF-8/SSE records, invalid finish reasons, incomplete tool results, stream-only responses, silent unsupported input | Incremental decoder, multiline SSE, explicit completion checks, tool-ID matching, synchronous JSON support, usage metadata, explicit unsupported-media errors |
| Model discovery | Stale fallback catalogue and narrow assumptions about response fields | Learn aliases from current discovery, preserve unknown fields and schemas, translate exact known RPCs only |
| Bridge lifecycle | Orphaned older proxy reused after upgrade; startup could restart the IDE | Check bundled script hash, serialize changes, restore previous endpoint, keep Bigroute startup separate from explicit Antigravity restart |
| Compatibility status | Local proxy health treated as proof that the IDE uses it | Inspect the running language server's actual endpoint and report incompatibility |
| Keychain | Denied reads became empty keys; settings rewrote credentials; ad-hoc development installation changed signing identity | Throw on access failure, retain metadata, retry explicitly, update keys in place only when changed, keep development app in DerivedData |
| Quota accuracy | 1% interpreted as 100%, boolean/numeric overflow, provider type replaced with UUID, Free plan treated as expired | Separate percentages from fractions, bound numeric conversions, preserve provider classification, require explicit expiration evidence |
| Refresh state | Removed providers or old refreshes could restore outdated account state; missing quota replaced with old measurements | Reconcile against current provider configuration, queue forced refreshes, invalidate refreshes superseded by manual actions, preserve failure timestamps |
| Persistence/UI | Shared snapshot writes, repeated sorting, old widget instructions | Per-user private snapshot writes with legacy read fallback, cached account ordering, remove obsolete widget code/docs, surface save/update errors |
| OTA | Hardcoded office channel, misleading button state, mutable numbered archives, non-atomic channel asset replacement | Use bundle channel and Sparkle readiness, immutable numbered archives, resumable publication, atomic signed feed branch, monotonic version checks, verify public bytes and archive metadata |

No new runtime dependencies or alternate remote transport were introduced. Existing signing roots, bundle identifiers, Keychain service, and Sparkle key remain unchanged.

## Mobile Remote Control: evidence and uncertainty

The user reports: opening one conversation works, then Back → another conversation displays **“Lost connection to the remote instance. Please wait a minute or refresh the page.”** The user reproduced the failure after the revised proxy was installed locally. This is direct evidence that the proxy changes alone have not resolved it.

The inspected Antigravity version is 2.12.2. Its language-server log shows Remote Control V2 connecting directly to `jetski-webchannel.googleapis.com:443`, with P2P disabled by the vendor flag. This connection is separate from the local generation proxy on port 50999.

On September 5, the log recorded an HTTP 400/close at 18:56, then upstream `close` frames and HTTP 400s around 22:11 and 22:20. Antigravity subsequently reconnected. Some large remote payloads were chunked. These observations do not establish which event corresponds to the user's navigation failure, or whether the cause is in the web client, relay, native language server, configuration, or Bridge interaction. No conversation contents or credentials are included here.

The installed Antigravity ASAR differs from the clean official copy only in its language-server endpoint selection. The official packaged launcher hardcodes `https://daily-cloudcode-pa.googleapis.com`; the modified copy reads `cloud_code_endpoint.txt`. The language-server executable itself matches the clean copy. Antigravity's main log also records code-signature rejection by its own updater. This is a separate confirmed installation issue; it does not prove the cause of the phone failure.

The revised Bridge was installed without restarting Antigravity, and its version/script hash were verified through the local health endpoint. Automated tests use local HTTP fixtures, not Google's live Remote Control relay. A locked Mac prevented the next UI reproduction and comparison. The lock was not bypassed.

## Required release validation

1. Unlock the Mac and reproduce phone navigation against the current Antigravity instance while collecting timestamps and transport diagnostics. Test both in-app Back and browser Back if their behavior differs.
2. Repeat the same navigation with Bridge off, after a graceful Antigravity restart. Compare with Bridge on using the same account, browser, and network. Do not infer causality solely from generic HTTP 400 messages.
3. If the problem persists without Bridge, compare with a clean vendor-signed Antigravity installation while preserving local data. If it only occurs with Bridge, isolate the specific request/response difference before another fix. Replacing the signed vendor app or disabling signature checks is not an update-resistant integration strategy.
4. Verify sustained phone navigation, refresh/reconnect, ordinary generation, streaming cancellation, and tool calls with the final candidate. Custom model compatibility needs a real Antigravity check.
5. Validate a signed office upgrade from an existing installation: preserve providers, maintain Keychain access, reach the newest version, relaunch Bigroute, and keep an active Antigravity session alive. An older client may already have staged an intermediate update; its installed code cannot be retroactively changed.
6. Date the changelog, ensure CI passes at `origin/main`, then tag `office-v1.6.0`. Verify both signed public feeds and published artifacts. Do not announce the phone issue as fixed until the actual phone test passes.

## Automated validation

Completed locally: **38 Swift tests, 24 Node tests, and the OTA publication integration test passed**. The unsigned Release build passed for arm64 and x86_64.

- Swift Testing: quota decoding and normalization, account availability and identity, cache migration with isolated fixtures, denied/corrupt credential handling, unchanged-key saves, denied key deletion, endpoint validation, read-only requests, account actions and import.
- Node test runner: real local upstream servers; repeated request switching/cancellation, compressed and large replies, truncated responses, deadlines, discovery preservation, model aliases, byte-split Vietnamese/emoji SSE, tools and usage, synchronous JSON, missing credentials and input validation.
- Python publication test: temporary bare Git remote and mock GitHub/download commands; first publication, idempotent retry, downgrade rejection, same-build mutation rejection, newer publication, and legacy feed consistency. This does not substitute for live GitHub or Sparkle installation testing.
- Xcode universal Release build with signing disabled; SwiftPM build/tests; monitoring-only gate; shell and workflow syntax; whitespace checks.

Only the completed checks reported in the task/CI are evidence of execution. Signed installation and phone checks above remain outstanding.

## Remaining compatibility limits

- Antigravity exposes no supported endpoint override in the inspected packaged launcher. Future internal schema/launcher changes can break Bridge. Bigroute detects some failures and preserves unknown traffic; it cannot guarantee compatibility with future vendor releases.
- Custom model placeholders depend on Antigravity's internal schema. Model capabilities and context limits are not inferred reliably from an arbitrary router ID. Prefer the official catalogue where possible and validate a custom model before team rollout.
- Bridge availability values keep router routes selectable; they are not measured upstream quotas. Actual account quota remains in Bigroute's provider dashboard.
- Stable signing and fewer Keychain operations reduce prompts. macOS may still request approval for an ad-hoc-to-signed migration, changed ACLs, or a locked Keychain. Access protection is retained.
- The Developer ID channel requires its existing Apple distribution credentials and was not notarized during this audit.

## Primary references

- [Antigravity Remote Control documentation](https://antigravity.google/docs/remote-control/)
- [Sparkle programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/)
- [Sparkle updater delegate](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)
- [Node HTTP API](https://nodejs.org/api/http.html)
- [Gemini generation API](https://ai.google.dev/api/generate-content)

Local installed source and logs provide the installation-specific evidence above. Public documentation does not establish the root cause of this incident.
