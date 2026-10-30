state: reviewed

# ANS-BRW-2 Rec-engine enroll secret at runtime + Add-to uses RecSuggestionFilter

- [x] EndpointConfig.recEngineEnroll parsed from `capabilities.recEngineEnroll` (malformed => ignored, doc still accepted); persisted with last-good doc
- [x] RemoteEndpoints.recEngineEnroll() provider (doc value, else compiled REC_ENGINE_ENROLL_SECRET); RecEngineClient default, RecCredentials default, CollectionsGraph delete path use it
- [x] Both Lambdas: enrollOk accepts comma-separated REC_ENROLL_SECRETS (+legacy REC_ENROLL_SECRET), constant-time, fail closed; deploy.sh updated (JSON --environment, rotation recipe); node tests added
- [x] src/config/endpointSchema.ts + validate-endpoints accept/validate capabilities.recEngineEnroll (vitest added); iOS ignores unknown keys (adoption optional)
- [x] AddToActions.suggestedTargets delegates to RecSuggestionFilter.resolveTargets
- [x] gradle :app:testDebugUnitTest :app:assembleDebug green (5348 tests, 0 failures); +6 Kotlin tests, +1 test in each Lambda suite, +1 vitest

## Files outside the owned list
- src/config/endpointSchema.ts, src/config/remoteEndpoints.test.ts (validator is shared by validate-endpoints.ts; additive)

## Questions for Levi
- Rotation recipe: deploy.sh with REC_ENROLL_SECRETS="old,new", publish endpoints doc with capabilities.recEngineEnroll=new (CONFIG_ONLY=1 scripts/deploy.sh prod), later drop old. Needs AWS deploy of both Lambdas to green (AWS_PROFILE=llc).
- Deploy.sh now writes only REC_ENROLL_SECRETS (legacy var dropped from the env once redeployed).

## Review

fixes applied

- MAJOR deploy.sh rotation recipe -> fixed. Recipe rewritten: the old secret (= the constant compiled into iOS Config.swift and pre-BRW-2 Android) must stay in REC_ENROLL_SECRETS until iOS reads capabilities.recEngineEnroll and old installs age out. deploy.sh now REFUSES a list that omits the Config.swift secret unless --force-drop-compiled. Regression test: scripts/lambda/rec-engine/test-deploy-guard.sh (3 cases).
- MINOR endpointSchema runtime vs strict -> fixed. validateEndpointDoc(raw, {strictCapabilities}) drops a malformed capability at runtime (PWA now matches Android, doc kept); scripts/validate-endpoints.ts passes strict so deploy still rejects typos. Vitest cases added.
- MINOR public plaintext secret threat model -> fixed (documented). index.mjs auth header records that the doc publishes the secret, rotation only invalidates leaked old values, MAX_PROFILES is the load-bearing guard. Levi should accept this knowingly.
- NIT test name enrollCapabilityDoesNotAffectEndpointEquality -> fixed (renamed enrollCapabilityChangesConfigEquality). apply() still reports changed=true on rotation (left as is).
- NIT suggestedTargetsDelegatesToRecSuggestionFilter -> rejected (optional; test guards equal output).
