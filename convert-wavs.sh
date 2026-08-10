#!/bin/bash

set -u

usage() {
    echo "Usage: $0 [source-directory]"
    echo "If no directory is supplied, a macOS folder picker will open."
}

if [ "$#" -gt 1 ]; then
    usage >&2
    exit 2
fi

if [ "$#" -eq 1 ]; then
    folder=$1
else
    if ! command -v osascript >/dev/null 2>&1; then
        echo "Error: supply a source directory when osascript is unavailable." >&2
        usage >&2
        exit 1
    fi

    if ! folder=$(osascript -e 'tell application "Finder"
        set folderPath to POSIX path of (choose folder with prompt "Select folder containing WAV files:")
        return folderPath
    end tell' 2>/dev/null); then
        echo "No folder selected. Exiting."
        exit 1
    fi
fi

if [ ! -d "$folder" ]; then
    echo "Error: source directory does not exist: $folder" >&2
    exit 1
fi

# Resolve the path once so relative-path removal remains reliable.
if ! source_dir=$(cd "$folder" 2>/dev/null && pwd -P); then
    echo "Error: could not access source directory: $folder" >&2
    exit 1
fi

if [ "$source_dir" = "/" ]; then
    echo "Error: the filesystem root cannot be used as the source directory." >&2
    exit 1
fi

for dependency in ffmpeg ffprobe; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        echo "Error: $dependency is required but was not found in PATH." >&2
        exit 1
    fi
done

converted_dir="$source_dir/converted"
if ! mkdir -p "$converted_dir"; then
    echo "Error: could not create output directory: $converted_dir" >&2
    exit 1
fi

echo "Selected folder: $source_dir"

# SD-card imports require 16-bit linear audio. FFprobe represents 24-bit PCM as
# pcm_s24le with an s32 sample format, so sample_fmt is not a reliable bit-depth
# test. Named key/value output also avoids depending on CSV field order.
is_compatible() {
    local file=$1
    local probe_output
    local key
    local value
    local codec_name=""
    local sample_rate=""
    local bits_per_sample=""

    if ! probe_output=$(ffprobe \
        -v error \
        -select_streams a:0 \
        -show_entries stream=codec_name,sample_rate,bits_per_sample \
        -of default=noprint_wrappers=1 \
        "$file" 2>/dev/null); then
        return 1
    fi

    while IFS='=' read -r key value; do
        case "$key" in
            codec_name) codec_name=$value ;;
            sample_rate) sample_rate=$value ;;
            bits_per_sample) bits_per_sample=$value ;;
        esac
    done <<< "$probe_output"

    if [ "$codec_name" != "pcm_s16le" ] || [ "$bits_per_sample" != "16" ]; then
        return 1
    fi

    case "$sample_rate" in
        16000|22050|32000|44100|48000|88200|96000|176400|192000)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

found_count=0
converted_count=0
copied_count=0
already_processed_count=0
failure_count=0

# NUL delimiters preserve spaces, newlines, and other valid filename characters.
# Process substitution keeps this loop in the parent shell so its counters persist.
while IFS= read -r -d '' file; do
    # find still visits the output tree on reruns; skip every file beneath it.
    case "$file" in
        "$converted_dir"/*) continue ;;
    esac

    found_count=$((found_count + 1))
    rel_path=${file#"$source_dir"/}
    target_file="$converted_dir/$rel_path"

    if [ -f "$target_file" ]; then
        echo "Already processed in previous run: $file"
        already_processed_count=$((already_processed_count + 1))
        continue
    fi

    target_dir=${target_file%/*}
    if ! mkdir -p "$target_dir"; then
        echo "Failed to create output directory for: $file" >&2
        failure_count=$((failure_count + 1))
        continue
    fi

    # Write beside the destination, then rename it into place. A failed copy or
    # conversion therefore cannot be mistaken for completed work on the next run.
    temporary_file="${target_file}.tmp.$$"

    if is_compatible "$file"; then
        echo "Copying compatible file: $file"
        if cp -p "$file" "$temporary_file" && mv -f "$temporary_file" "$target_file"; then
            copied_count=$((copied_count + 1))
        else
            rm -f "$temporary_file"
            echo "Failed to copy: $file" >&2
            failure_count=$((failure_count + 1))
        fi
    else
        echo "Converting incompatible file: $file"
        if ffmpeg \
            -v error \
            -nostdin \
            -y \
            -i "$file" \
            -map 0:a:0 \
            -c:a pcm_s16le \
            -ar 44100 \
            -f wav \
            "$temporary_file" &&
            mv -f "$temporary_file" "$target_file"; then
            converted_count=$((converted_count + 1))
        else
            rm -f "$temporary_file"
            echo "Failed to convert: $file" >&2
            failure_count=$((failure_count + 1))
        fi
    fi
done < <(find "$source_dir" -type f -iname '*.wav' ! -name '._*' -print0)

if [ "$found_count" -eq 0 ]; then
    echo "No WAV files were found to process."
    rmdir "$converted_dir" 2>/dev/null || true
    exit 0
fi

echo "Processing complete!"
echo "- Converted: $converted_count"
echo "- Copied compatible: $copied_count"
echo "- Already processed: $already_processed_count"
echo "- Failed: $failure_count"
echo "All processed files are located in: $converted_dir"
echo "Original files remain untouched."

if [ "$failure_count" -gt 0 ]; then
    echo "Some files could not be processed." >&2
    exit 1
fi

echo "Your samples are now ready for SP-404MKII SD-card import. Enjoy!"
