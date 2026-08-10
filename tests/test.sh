#!/bin/bash

set -u

script_dir=$(cd "$(dirname "$0")/.." && pwd -P)
converter="$script_dir/convert-wavs.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for dependency in ffmpeg ffprobe; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        echo "SKIP: $dependency is not installed."
        exit 0
    fi
done

test_root=$(mktemp -d "${TMPDIR:-/tmp}/sp404-wav-test.XXXXXX") || exit 1
cleanup() {
    rm -rf "$test_root"
}
trap cleanup EXIT HUP INT TERM

source_dir="$test_root/source [samples]"
reference_dir="$test_root/original [files]"
mkdir -p "$source_dir/nested folder"

make_wav() {
    local codec=$1
    local rate=$2
    local destination=$3

    ffmpeg -v error -f lavfi -i "sine=frequency=440:duration=0.2" \
        -c:a "$codec" -ar "$rate" "$destination"
}

make_wav pcm_s16le 44100 "$source_dir/compatible 44.1.wav"
make_wav pcm_s16le 48000 "$source_dir/nested folder/compatible 48.WAV"
make_wav pcm_s24le 44100 "$source_dir/nested folder/24-bit source.wav"
make_wav pcm_s32le 44100 "$source_dir/32-bit integer.wav"
make_wav pcm_f32le 48000 "$source_dir/float [sample].wav"
unusual_file="$source_dir/nested folder/line"$'\n'"break.wav"
make_wav pcm_s16le 44100 "$unusual_file"

cp -R "$source_dir" "$reference_dir"

if ! first_output=$("$converter" "$source_dir" 2>&1); then
    echo "$first_output" >&2
    fail "initial conversion returned a failure"
fi

case "$first_output" in *"- Converted: 3"*) ;; *) fail "expected three conversions" ;; esac
case "$first_output" in *"- Copied compatible: 3"*) ;; *) fail "expected three copies" ;; esac
case "$first_output" in *"- Already processed: 0"*) ;; *) fail "expected no initial skips" ;; esac
case "$first_output" in *"- Failed: 0"*) ;; *) fail "expected no initial failures" ;; esac

while IFS= read -r -d '' reference_file; do
    rel_path=${reference_file#"$reference_dir"/}
    cmp -s "$reference_file" "$source_dir/$rel_path" || fail "original changed: $rel_path"
    [ -f "$source_dir/converted/$rel_path" ] || fail "missing output: $rel_path"
done < <(find "$reference_dir" -type f -print0)

probe_value() {
    local file=$1
    local field=$2

    ffprobe -v error -select_streams a:0 -show_entries "stream=$field" \
        -of default=noprint_wrappers=1:nokey=1 "$file"
}

assert_audio() {
    local file=$1
    local expected_codec=$2
    local expected_rate=$3
    local actual_codec
    local actual_rate

    actual_codec=$(probe_value "$file" codec_name)
    actual_rate=$(probe_value "$file" sample_rate)
    [ "$actual_codec" = "$expected_codec" ] || fail "$file uses $actual_codec, not $expected_codec"
    [ "$actual_rate" = "$expected_rate" ] || fail "$file uses $actual_rate Hz, not $expected_rate Hz"
}

assert_audio "$source_dir/converted/compatible 44.1.wav" pcm_s16le 44100
assert_audio "$source_dir/converted/nested folder/compatible 48.WAV" pcm_s16le 48000
assert_audio "$source_dir/converted/nested folder/24-bit source.wav" pcm_s16le 44100
assert_audio "$source_dir/converted/32-bit integer.wav" pcm_s16le 44100
assert_audio "$source_dir/converted/float [sample].wav" pcm_s16le 44100
assert_audio "$source_dir/converted/nested folder/line"$'\n'"break.wav" pcm_s16le 44100

if ! rerun_output=$("$converter" "$source_dir" 2>&1); then
    echo "$rerun_output" >&2
    fail "rerun returned a failure"
fi

case "$rerun_output" in *"- Converted: 0"*) ;; *) fail "rerun unexpectedly converted files" ;; esac
case "$rerun_output" in *"- Copied compatible: 0"*) ;; *) fail "rerun unexpectedly copied files" ;; esac
case "$rerun_output" in *"- Already processed: 6"*) ;; *) fail "expected six rerun skips" ;; esac
case "$rerun_output" in *"- Failed: 0"*) ;; *) fail "rerun reported a failure" ;; esac

bad_source="$test_root/bad source"
mkdir -p "$bad_source"
printf '%s\n' "not a WAV file" > "$bad_source/broken.wav"

if bad_output=$("$converter" "$bad_source" 2>&1); then
    fail "invalid audio should produce a nonzero exit status"
fi

case "$bad_output" in *"- Failed: 1"*) ;; *) fail "expected one reported failure" ;; esac
[ ! -f "$bad_source/converted/broken.wav" ] || fail "failed conversion left a completed output"

echo "PASS: converter integration checks completed successfully."
