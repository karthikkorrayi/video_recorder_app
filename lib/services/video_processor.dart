import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
// import 'package:ffmpeg_kit_flutter_new/ffmpeg_probe_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class VideoProcessor {
  // Step 1: Get video duration in seconds
  Future<double> getDuration(String inputPath) async {
    final session = await FFprobeKit.getMediaInformation(inputPath);
    final info = session.getMediaInformation();
    return double.parse(info?.getDuration() ?? '0');
  }

  // Step 2: Process video — mute audio, set 9:16 ratio, 30fps, compress
  Future<String> processVideo(String inputPath) async {
    final dir = await getTemporaryDirectory();
    final outputPath = '${dir.path}/processed_video.mp4';

    // -an = no audio, crop to 9:16, 30fps, CRF 28 = good quality small size
    final command = '-i "$inputPath" '
        '-vf "crop=ih*(9/16):ih,fps=30" '
        '-an '               // <-- removes audio track
        '-c:v libx264 '
        '-crf 28 '
        '-preset fast '
        '"$outputPath"';

    await FFmpegKit.execute(command);
    return outputPath;
  }

  // Step 3: Split processed video into exactly 5 equal chunks
  Future<List<String>> splitIntoFiveChunks(String processedPath) async {
    final dir = await getTemporaryDirectory();
    final duration = await getDuration(processedPath);
    final chunkDuration = duration / 5;
    final List<String> chunkPaths = [];

    for (int i = 0; i < 5; i++) {
      final startTime = i * chunkDuration;
      final chunkPath = '${dir.path}/chunk_${i + 1}.mp4';

      final command = '-i "$processedPath" '
          '-ss $startTime '
          '-t $chunkDuration '
          '-c copy '          // fast copy, no re-encode
          '"$chunkPath"';

      await FFmpegKit.execute(command);
      chunkPaths.add(chunkPath);
    }

    return chunkPaths; // [chunk_1.mp4, chunk_2.mp4, ..., chunk_5.mp4]
  }
}