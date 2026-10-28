// Host tool: emits the golden vectors KernelsTest compares the Kotlin kernels against.
//   clang++ -std=c++17 -O1 -I.. tools/golden.cpp ../fx_kernels.cpp -o /tmp/golden && /tmp/golden > ../../../../test/resources/studio/fx-golden.txt
// (run from cpp/pdjdsp/tools). Inputs here MUST match KernelsTest.goldenInputs().
#include "fx_kernels.h"
#include <cmath>
#include <cstdio>
int main() {
    const int N = 2048;
    std::vector<float> L(N, 0.f), R(N, 0.f);
    L[0] = 1.f; R[0] = 0.5f;
    float* ch[2] = {L.data(), R.data()};
    pdj::TrackFx t; t.configure(44100, 2);
    pdj::TrackFxParams p; p.eqLowDb = 6; p.eqMidDb = -4; p.eqHighDb = 3; p.reverb = 0.5; p.delay = 0.4; p.chorus = 0.5; p.bpm = 1500;
    t.update(p); t.process(ch, 2, N);
    printf("TRACK %d\n", N);
    for (int i = 0; i < N; i++) printf("%.9g %.9g\n", L[i], R[i]);
    std::vector<float> a(N), b(N);
    for (int i = 0; i < N; i++) { a[i] = (float)(0.5 * sin(i * 0.05)); b[i] = (float)(0.3 * sin(i * 0.03)); }
    float* m[2] = {a.data(), b.data()};
    pdj::MasterFx f; f.configure(44100, 2);
    pdj::MasterFxParams q; q.phaser = true; q.ringMod = true; q.brazil = true; q.drive = true; q.masterGain = 0.8; q.bpm = 120;
    f.update(q);
    float* m2[2] = {a.data() + 1024, b.data() + 1024};
    f.process(m, 2, 1024, 0); f.process(m2, 2, 1024, 1024);
    printf("MASTER %d\n", N);
    for (int i = 0; i < N; i++) printf("%.9g %.9g\n", a[i], b[i]);
}
