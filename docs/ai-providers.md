# Capture AI providers

In Add or an Assistant conversation, tap the **AI provider** (sparkles) toolbar button, or open **Connection → AI provider**. Choose a provider and model, enter a personal API key, and save. Saving settings does not make an inference request. Keys are device-only Keychain items scoped to the provider and normalized endpoint. An empty replacement field keeps a saved key; **Remove saved key → Save** deletes it. Choosing an external provider is enough to send capture text; there is no separate consent switch.

The default remains on-device Apple Intelligence. External providers do not require Apple Intelligence hardware or a PCC entitlement. A missing key or retired model blocks that provider; HowMuch never silently switches to another service. Changes apply to the next request, including an explicit Retry.

## Shipped catalog

The source of truth is [`AIModels.json`](../apps/ios/HowMuch/Capture/AIModels.json), bundled as an app resource. Provider/model choices are rendered from it; no separate list lives in the UI.

| Provider | Model IDs | API |
| --- | --- | --- |
| OpenCode Go | `gpt-5.6-luna` | Responses |
| OpenCode Go | `deepseek-v4-flash-vision-exp` | Chat Completions |
| OpenRouter | `openai/gpt-5.6-luna`, `deepseek/deepseek-v4-flash-vision-exp` | Chat Completions |
| OpenAI | `gpt-5.6-luna` | Responses |
| DeepSeek | `deepseek-v4-flash-vision-exp` | Chat Completions |

“DeepSeek V4 Flash Exp” is shown by its documented name, **DeepSeek V4 Flash Vision Exp**. This integration sends extracted receipt **text**, not images, even for vision-capable models. Vision upload is not part of BYOK.

OpenCode Go's [client policy](https://opencode.ai/docs/go/#where-can-i-use-it) expects coding-agent traffic. The preset is available, but users must confirm their subscription permits HowMuch. Requests identify as `HowMuch/1.0`, not a coding agent, and use a random conversation UUID for `x-opencode-session` (no account/user identifiers).

## Updating models (including agent updates)

1. Verify the provider's current official docs and exact API model ID. OpenRouter prefixes IDs with the model vendor; direct providers and Go do not. Do not invent aliases or assume OpenAI-compatible means every parameter is supported.
2. Add/edit an entry in `AIModels.json`:
   - `id`: exact API model ID; `name`: visible label.
   - `api`: `responses` or `chatCompletions`.
   - `format`: `jsonSchema` for verified structured-output support; otherwise `jsonObject` for a provider supporting JSON mode. Both require complete, validated capture JSON locally.
   - `reasoning`: `openAI` disables reasoning with `effort: none`; `openRouter` uses `reasoning.enabled: false`; `deepSeek` uses `thinking.type: disabled`; `providerDefault` adds no reasoning parameter. These presets prioritize short extraction latency, not deep reasoning.
3. Update the provider's `notice` and documentation link when its privacy or usage contract changes. Preserve provider IDs and endpoint scoping; changing an endpoint must not forward an existing key to it. No runtime catalog downloads or automatic model substitution.
4. Update catalog assertions in `CaptureAITests` if an explicitly supported model is retired. Run the catalog/request/stream/validation tests and representative Settings screenshots at default and accessibility text sizes. Use `scripts/ios-xcodebuild.sh` per the iOS guidance, with matching build/test products.
5. Live smoke tests need explicit authorization and a securely supplied key. Use synthetic text, never a personal ledger or uploaded financial image. Record latency, actual model ID, and result validation, without logging keys or raw private prompts. Mocked tests are not evidence of a live provider response.

Adding another model with an existing capability combination requires only catalog data and tests/docs—not transport or SwiftUI branching. A genuinely new wire protocol needs a separate transport implementation and contract tests. **Custom endpoint** supports an HTTPS base URL, exact model ID, and either existing protocol using JSON-object output; it does not infer undocumented model-specific options.

### Simulator Keychain validation

The real Keychain round-trip test (`CaptureAITests/testKeychainCanReplaceAndDeleteOnlyItsOwnCredential`) is separate from the in-memory settings tests. It needs a test host that carries an `application-identifier` entitlement; an entitlement-less host built with `CODE_SIGNING_ALLOWED=NO` fails every `SecItem*` call with `errSecMissingEntitlement` (`-34018`). That failure is an environment signal, not a code bug: do not skip the test or substitute insecure storage.

`scripts/ios-xcodebuild.sh` therefore signs simulator builds ad hoc by default:

```text
CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE= PROVISIONING_PROFILE_SPECIFIER=
```

This is Xcode's normal simulator packaging/link/sign pipeline. It needs no Apple certificate, provisioning profile, network access, archive, or publication, and the product cannot run on a device. Xcode's generated `HowMuch.app-Simulated.xcent` (with `application-identifier` `PQ6U5ESLN2.sg.soon.howmuch` and the tracked entitlements) is embedded in `__TEXT,__entitlements`; the native signature is `adhoc` with no team or authority. Keep the existing team, bundle IDs, and tracked entitlements. Do not attach iOS entitlements with `codesign --entitlements` directly: that passed static verification but failed runtime launch with AMFI's restricted-entitlement rejection.

`HOWMUCH_SIM_SIGNING=unsigned` restores `CODE_SIGNING_ALLOWED=NO` (for example, to reproduce an unsigned-only problem); the Keychain test is then expected to fail with `-34018`. Rebuild with `build-for-testing` whenever you switch modes, and pass the same mode to `test-without-building`. To check a build, `codesign -dv build/xcode/DerivedData-simulator/Build/Products/Debug-iphonesimulator/HowMuch.app` should report `flags=0x2(adhoc)`. An unsigned build also says `Signature=adhoc`, but its flags include `linker-signed` and the binary has no `__TEXT,__entitlements` section (`otool -l …/HowMuch.app/HowMuch | grep __entitlements`). There should be no `embedded.mobileprovision` either way. Never treat zero collected tests as success or clear simulator data to manufacture a pass.

## Privacy and recovery boundaries

- External requests contain the entered text, selected receipt transcripts, current unsaved drafts, bounded recent instructions/answers, and account/category names. They do not contain the full ledger, images, HowMuch login tokens, or provider keys inside the prompt. Prior answers can contain spending summaries.
- The model proposes drafts or a read-only query specification. Existing mapping, ambiguity resolution, account/transfer rules, and explicit Save remain authoritative. No model tool calls are executed.
- Responses requests set `store: false`. OpenRouter requests `provider.data_collection: deny` and `require_parameters: true`. These are not blanket zero-retention guarantees; gateway and upstream provider policies still apply.
- Each request uses an ephemeral URLSession with no cache, cookies, credential storage, or redirects. HTTP/provider failures use app-owned messages instead of echoing provider bodies.
- The UI shows real waiting/receiving/checking/fetching stages and elapsed time, not fabricated thoughts or unfinished financial fields. Output is applied only after a successful terminal event and full payload validation. There is a 120-second whole-turn watchdog, a 45-second transport inactivity limit, a 64 KiB prompt limit, a 1 MiB response limit, and a 4,096-token output budget. Truncated output fails without changing drafts.
- Stop and timeout invalidate the generation before a late result can apply. Input and drafts survive for Retry or Add manually; closing the conversation still preserves workspace-owned work.

## Official API references

- [OpenCode Go endpoints and privacy](https://opencode.ai/docs/go/)
- [OpenRouter models](https://openrouter.ai/api/v1/models) and [structured output](https://openrouter.ai/docs/guides/features/structured-outputs)
- [OpenAI GPT 5.6 Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna) and [structured output](https://developers.openai.com/api/docs/guides/structured-outputs)
- [DeepSeek Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion)

PCC is tracked separately in [#142](https://github.com/yjsoon/howmuch/issues/142); this implementation addresses [#143](https://github.com/yjsoon/howmuch/issues/143).
