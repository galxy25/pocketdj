#!/usr/bin/env bash
# R8 keep gate: assert that every class name that is PERSISTED or looked up BY NAME at runtime
# survived obfuscation unchanged in a release mapping.txt. Run by release-aab.sh after bundleRelease;
# also usable by hand:  android/scripts/check-r8-mapping.sh app/build/outputs/mapping/release/mapping.txt
#
# Why each group matters (the 1.0.0 release shipped -dontobfuscate, so persisted names are the
# unobfuscated FQNs):
#   * WorkManager workers + InputMergers: the FQN is stored in WorkManager's Room DB (periodic work
#     enqueued by an older build must still resolve after an update).
#   * Glance provider: GlanceAppWidgetManager stores its canonicalName; getGlanceIds() looks it up.
#   * Manifest components: referenced by name from the manifest, PendingIntents, shortcuts.
#   * JNI: libpdjdsp exports Java_com_levi_pocketdj_studio_audio_NativeDsp_*; libappleMusicSDK /
#     libsigx FindClass com/apple/android/**, org/bytedeco/javacpp/**, com/shazam/recognition/**.
#   * Tink protobuf-lite reads message fields by NAME (EncryptedSharedPreferences keysets).
set -euo pipefail
MAP="${1:?usage: check-r8-mapping.sh <mapping.txt>}"
[[ -s "$MAP" ]] || { echo "R8 mapping missing or empty: $MAP" >&2; exit 1; }

fail=0
classes="$(mktemp)"; trap 'rm -f "$classes"' EXIT
# "orig.Name -> new.Name:" lines only (members are indented).
grep -E '^[^ #][^ ]* -> [^ ]+:$' "$MAP" | sed -E 's/ -> /\t/; s/:$//' > "$classes"

kept() { # $1 = FQN that must be present and unrenamed
  local new
  new="$(awk -F'\t' -v c="$1" '$1==c {print $2; exit}' "$classes")"
  if [[ -z "$new" ]]; then echo "FAIL missing from mapping (stripped?): $1"; fail=1
  elif [[ "$new" != "$1" ]]; then echo "FAIL renamed: $1 -> $new"; fail=1
  else echo "ok   $1"; fi
}

for c in \
  com.levi.pocketdj.PocketDjApplication \
  com.levi.pocketdj.MainActivity \
  com.levi.pocketdj.playback.PlaybackService \
  com.levi.pocketdj.widget.NowPlayingWidget \
  com.levi.pocketdj.widget.NowPlayingWidgetReceiver \
  com.levi.pocketdj.widget.WidgetActionReceiver \
  com.levi.pocketdj.data.location.FusedLocationReceiver \
  com.levi.pocketdj.studio.audio.NativeDsp \
  com.levi.pocketdj.work.RipReconcileWorker \
  com.levi.pocketdj.work.StoragePruneWorker \
  com.levi.pocketdj.data.transfers.BurnDownloadWorker \
  com.levi.pocketdj.data.transfers.RipReconcileWorker \
  com.levi.pocketdj.data.transfers.StoragePruneWorker \
  com.levi.pocketdj.data.applemusic.AmAutoSyncWorker \
  com.levi.pocketdj.data.location.LocationPollWorker \
  androidx.work.OverwritingInputMerger \
  androidx.work.impl.workers.ConstraintTrackingWorker \
  androidx.glance.session.SessionWorker \
  com.apple.android.music.playback.controller.MediaPlayerControllerFactory \
  org.bytedeco.javacpp.Pointer \
  org.bytedeco.javacpp.Loader \
  'com.shazam.recognition.Searcher$Result' \
  ; do kept "$c"; done

# Every top-level app class named *Worker (new workers are covered without editing this list).
while IFS=$'\t' read -r orig new; do
  [[ "$orig" == com.levi.pocketdj.* && "$orig" == *Worker && "$orig" != *'$'* ]] || continue
  [[ "$orig" == "$new" ]] || { echo "FAIL renamed worker: $orig -> $new"; fail=1; }
done < "$classes"

# Whole-SDK keeps (JavaCPP / JNI callbacks by name; ShazamKit's Gson+Retrofit models). R8's own
# desugaring lambdas ($$ExternalSynthetic*) are new classes, not SDK names.
renamed_sdk="$(awk -F'\t' '($1 ~ /^(com\.apple\.android\.|org\.bytedeco\.javacpp\.|com\.shazam\.shazamkit\.)/) && $1 !~ /\$\$ExternalSynthetic/ && $1 != $2 && $2 !~ /^R8\$\$REMOVED/' "$classes" | head -5)"
[[ -z "$renamed_sdk" ]] || { echo "FAIL renamed SDK classes:"; echo "$renamed_sdk"; fail=1; }

# Tink protobuf-lite field names (reflection by name).
if awk '/^com\.google\.crypto\.tink\.proto\.AesGcmKey -> /{f=1;next} /^[^ #]/{f=0} f' "$MAP" | grep -qE ' keyValue_ -> keyValue_$'; then
  echo "ok   tink AesGcmKey.keyValue_"
else
  echo "FAIL tink AesGcmKey.keyValue_ renamed or missing"; fail=1
fi

[[ $fail == 0 ]] && echo "R8 mapping gate: PASS" || { echo "R8 mapping gate: FAIL" >&2; exit 1; }
