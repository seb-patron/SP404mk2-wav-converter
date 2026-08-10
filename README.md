# SP-404MKII WAV File Converter

This small Bash utility creates an SD-card-ready copy of a WAV sample library for the Roland SP-404MKII. It preserves the original folder structure and never modifies the source files.

> For the story behind the tool, see the [SP-404MKII WAV converter blog post](https://sebpatron.com/sp404mk2-wav-converter/).

## What it does

- Recursively finds `.wav` files (case-insensitive) in the selected folder
- Copies compatible files without transcoding them
- Converts incompatible files to 16-bit, 44.1 kHz linear PCM WAV
- Mirrors the source hierarchy inside a `converted` subdirectory
- Skips a source path when its matching output file already exists
- Handles spaces and other valid filename characters
- Reports converted, copied, skipped, and failed file counts

## Compatibility target

Roland distinguishes between importing from an SD card and importing through the SP-404MKII app:

- **SD card:** 16-bit linear WAV/AIFF and MP3
- **SP-404MKII app:** WAV, AIFF, MP3, FLAC, and M4A (ALAC/AAC), with 16- and 24-bit support for applicable lossless formats

See Roland's [current import-format documentation](https://support.roland.com/hc/en-us/articles/4408190553883-SP-404MK2-What-audio-file-formats-can-be-imported-into-the-SP-404MK2) and [SP-404MKII app guide](https://static.roland.com/assets/media/pdf/SP-404MK2_app_eng04_W.pdf).

This utility intentionally targets the stricter SD-card workflow. A file is copied as compatible only when FFprobe identifies it as 16-bit linear PCM at one of Roland's supported sample rates: 16, 22.05, 32, 44.1, 48, 88.2, 96, 176.4, or 192 kHz. Other WAV files are converted to 16-bit, 44.1 kHz linear PCM. That remains a conservative, widely compatible output; the sampler converts imported audio to its internal 48 kHz/16-bit format.

## Requirements

- macOS when using the folder picker; other platforms can pass a directory argument
- [FFmpeg](https://ffmpeg.org/), including `ffprobe`

With [Homebrew](https://brew.sh/) installed:

```bash
brew install ffmpeg
```

## Usage

Make the script executable:

```bash
chmod +x convert-wavs.sh
```

Open the macOS folder picker:

```bash
./convert-wavs.sh
```

Or pass the samples directory directly:

```bash
./convert-wavs.sh "/path/to/samples"
```

The script creates `/path/to/samples/converted` and places every successfully processed WAV there: compatible files are copied and incompatible files are converted. Existing output files are left alone on later runs.

## Testing

Run the integration test:

```bash
./tests/test.sh
```

The test creates short synthetic audio fixtures with FFmpeg, so the repository does not need to include copyrighted samples or opaque binary test data. It covers:

- compatible 44.1 and 48 kHz 16-bit PCM files that should be copied
- 24-bit PCM, 32-bit integer PCM, and 32-bit float files that should be converted
- nested directories, spaces, brackets, an uppercase `.WAV` extension, and a newline in a filename
- output metadata, unchanged source files, reruns, and invalid-input failure handling

### Safely try your own samples

The converter never overwrites source WAVs, but testing a duplicate first makes it easy to inspect or discard the whole result:

```bash
cp -R "/path/to/my samples" "/path/to/my samples test"
./convert-wavs.sh "/path/to/my samples test"
```

Inspect an output file with FFprobe:

```bash
ffprobe -v error -select_streams a:0 \
  -show_entries stream=codec_name,sample_rate,bits_per_sample \
  -of default=noprint_wrappers=1 \
  "/path/to/my samples test/converted/example.wav"
```

Converted files should report `codec_name=pcm_s16le`, `sample_rate=44100`, and `bits_per_sample=16`. Compatible copied files keep their supported original sample rate.

## Limitations

- Existing outputs are skipped by path. If a source file changes, remove its corresponding file from `converted` before rerunning.
- Only WAV inputs are processed; the SP-404MKII supports additional import formats.
- Extremely short samples (under 100 ms) and some filenames may still be rejected by the sampler even when their audio encoding is supported.

## License

MIT
