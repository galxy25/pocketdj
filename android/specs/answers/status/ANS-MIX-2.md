state: in-progress

# ANS-MIX-2 Mix tempo/pitch on C++ Signalsmith (Q6a)

- [x] C++ RtStretch (stretch_rt.{h,cpp}) + JNI + CMake
- [x] TimeStretcher interface, NativeTimePitch (+RatioPlanner, RtStretchBackend), TimePitch fallback
- [x] DeckChain uses TimeStretchers.create; publishes latencyFrames / audibleLagSeconds
- [x] Latency compensation: DeckController.trueSeconds, MixEngine/GlideMachine phase-align (PhaseAlignMath)
- [x] JVM tests + instrumented tests written
- [ ] Gradle build/test green, count moved
