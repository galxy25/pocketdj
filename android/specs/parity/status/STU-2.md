state: in-progress

# STU-2 — Studio native DSP lib + OboeSink + StudioRender/RenderGraph + NDK wiring

## Checklist
- [x] NDK 27.2 + CMake 3.22.1 installed via sdkmanager (not present before); Gradle externalNativeBuild + Oboe prefab + abiFilters
- [x] cpp/pdjdsp: fx_kernels, mixer, sf2_voice (tsf), stretch (Signalsmith exact), oboe_sink (ring + data callback), jni
- [x] Kotlin kernel mirrors (TrackFxKernel / MasterFxKernel) + host golden tool
- [x] OboeSink (audio/core), NativeDsp, StudioAudio, RenderGraph, StudioRender
- [ ] JVM tests (StudioAudioTest, KernelsTest, StudioRenderTest, OboeSinkTest, RenderGraphTest)
- [ ] instrumented smoke (compile-only)
