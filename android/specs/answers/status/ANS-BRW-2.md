state: implemented

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
