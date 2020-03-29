import 'dart:async';
import 'dart:convert';
// import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:file/local.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Audio Recorder Plugin
class FlutterAudioRecorder {
  static const MethodChannel _channel =
      const MethodChannel('flutter_audio_recorder');
  static const String DEFAULT_EXTENSION = '.m4a';
  static LocalFileSystem fs = LocalFileSystem();
  static const int AUDIO_SNIPPET_SECONDS = 2;   // Length of snippet

  String _path;
  String _extension;
  Recording _recording;
  int _sampleRate;
  List<Int16List> _audioSnippet;    // Audio data sequences
  Duration _snippetDuration;
  Timer _timer;

  // ngrok on laptop (regrettably)
  // You have to type: ngrok http [YOUR_PORT] to set up a session
  // use desktop IP address otherwise
  String url = "ws://66d76f20.ngrok.io";

  WebSocketChannel wsChannel;
  JsonEncoder jsonEncoder;

  Future _initRecorder;
  Future get initialized => _initRecorder;
  Recording get recording => _recording;
  Stream get ws => wsChannel.stream;

  FlutterAudioRecorder(String path,
      {AudioFormat audioFormat, int sampleRate = 44100}) {
    _initRecorder = _init(path, audioFormat, sampleRate);
  }

  /// Initialized recorder instance
  Future _init(String path, AudioFormat audioFormat, int sampleRate) async {
    wsChannel = IOWebSocketChannel.connect(url);
    jsonEncoder = JsonEncoder();

    String extension;
    String extensionInPath;

    // Prepare for first audio snippet
    // _audioSnippet = List(); <---- performed in audioDataCallback()
    _snippetDuration = Duration(seconds: AUDIO_SNIPPET_SECONDS);

    if (path != null) {
      // Extension(.xyz) of Path
      extensionInPath = p.extension(path);
      // Use AudioFormat
      if (audioFormat != null) {
        // .m4a != .m4a
        if (_stringToAudioFormat(extensionInPath) != audioFormat) {
          // use AudioOutputFormat
          extension = _audioFormatToString(audioFormat);
          path = p.withoutExtension(path) + extension;
        } else {
          extension = p.extension(path);
        }
      } else {
        // Else, Use Extension that inferred from Path
        // if extension in path is valid
        if (_isValidAudioFormat(extensionInPath)) {
          extension = extensionInPath;
        } else {
          extension = DEFAULT_EXTENSION; // default value
          path += extension;
        }
      }
      File file = fs.file(path);
      if (await file.exists()) {
        throw new Exception("A file already exists at the path :" + path);
      } else if (!await file.parent.exists()) {
        throw new Exception("The specified parent directory does not exist");
      }
    } else {
      extension = DEFAULT_EXTENSION; // default value
    }
    _path = path;
    _extension = extension;
    _sampleRate = sampleRate;

    Map<String, Object> response;
    var result = await _channel.invokeMethod('init',
        {"path": _path, "extension": _extension, "sampleRate": _sampleRate});

    if (result != false) {
      response = Map.from(result);
    }

    _recording = new Recording()
      ..status = _stringToRecordingStatus(response['status'])
      ..metering = new AudioMetering(
          averagePower: -120, peakPower: -120, isMeteringEnabled: true);

    return;
  }

  /// Request an initialized recording instance to be [started]
  /// Once executed, audio recording will start working and
  /// a file will be generated in user's file system
  Future start() async {
    _audioSnippet = List();
    _channel.setMethodCallHandler(_handleNativeMethodCall);

    await _channel.invokeMethod('start');

    _timer = new Timer.periodic(_snippetDuration, (Timer timer) {
      // Pass data from _audioSnippet somewhere
      print("_audioSnippet's length is ${_audioSnippet.length}.");
      wsChannel.sink.add(jsonEncoder.convert(_audioSnippet)); // Sending json of audio

      // Empty out _audioSnippet
      _audioSnippet = List();
    });
  }

  /// Request currently [Recording] recording to be [Paused]
  /// Note: Use [current] to get latest state of recording after [pause]
  Future pause() async {
    return _channel.invokeMethod('pause');
  }

  /// Request currently [Paused] recording to continue
  Future resume() async {
    return _channel.invokeMethod('resume');
  }

  /// Request the recording to stop
  /// Once its stopped, the recording file will be finalized
  /// and will not be start, resume, pause anymore.
  Future<Recording> stop() async {
    Map<String, Object> response;
    var result = await _channel.invokeMethod('stop');

    if (result != null) {
      response = Map.from(result);
      _responseToRecording(response);
    }

    // Stop the timer if it is currently active,
    // preventing any further passage of _audioSnippet's data to server
    if (_timer.isActive) {
      wsChannel.sink.close();
      _timer.cancel();
    }

    return _recording;
  }

  /// Ask for current status of recording
  /// Returns the result of current recording status
  /// Metering level, Duration, Status...
  Future<Recording> current({int channel = 0}) async {
    Map<String, Object> response;

    var result = await _channel.invokeMethod('current', {"channel": channel});

    if (result != null && _recording?.status != RecordingStatus.Stopped) {
      response = Map.from(result);
      _responseToRecording(response);
    }

    return _recording;
  }

  /// Returns the result of record permissionijggle
  static Future<bool> get hasPermissions async {
    bool hasPermission = await _channel.invokeMethod('hasPermissions');
    return hasPermission;
  }

  /// Mediates native calls from Android/iOS to Dart.
  /// Currently handles receiving snippets of short[] audio data.
  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    // print("call.arguments: ${call.arguments}");
    // print("call.arguments type: ${call.arguments.runtimeType}");
    switch (call.method) {
      case "sendAudioData":
        // print("call.arguments.runtimeType: ${call.arguments.runtimeType}.");
        Int16List result = new Int16List.fromList(call.arguments);

        // print("result.runtimeType: ${result.runtimeType}");
        _audioSnippet.add(result);
        // print("Dart: Added to _audioSnippet.");
        break;
      default:
        throw new ArgumentError("Unknown method: ${call.method}");
    }

    return null;
  }

  void dispose()
  {
    wsChannel.sink.close();
  }

  ///  util - response msg to recording object.
  void _responseToRecording(Map<String, Object> response) {
    if (response == null) return;

    _recording.duration = new Duration(milliseconds: response['duration']);
    _recording.path = response['path'];
    _recording.audioFormat = _stringToAudioFormat(response['audioFormat']);
    _recording.extension = response['audioFormat'];
    _recording.metering = new AudioMetering(
        peakPower: response['peakPower'],
        averagePower: response['averagePower'],
        isMeteringEnabled: response['isMeteringEnabled']);
    _recording.status = _stringToRecordingStatus(response['status']);
  }

  /// util - verify if extension string is supported
  static bool _isValidAudioFormat(String extension) {
    switch (extension) {
      case ".wav":
      case ".mp4":
      case ".aac":
      case ".m4a":
        return true;
      default:
        return false;
    }
  }

  /// util - Convert String to Enum
  static AudioFormat _stringToAudioFormat(String extension) {
    switch (extension) {
      case ".wav":
        return AudioFormat.WAV;
      case ".mp4":
      case ".aac":
      case ".m4a":
        return AudioFormat.AAC;
      default:
        return null;
    }
  }

  /// Convert Enum to String
  static String _audioFormatToString(AudioFormat format) {
    switch (format) {
      case AudioFormat.WAV:
        return ".wav";
      case AudioFormat.AAC:
        return ".m4a";
      default:
        return ".m4a";
    }
  }

  /// util - Convert String to Enum
  static RecordingStatus _stringToRecordingStatus(String status) {
    switch (status) {
      case "unset":
        return RecordingStatus.Unset;
      case "initialized":
        return RecordingStatus.Initialized;
      case "recording":
        return RecordingStatus.Recording;
      case "paused":
        return RecordingStatus.Paused;
      case "stopped":
        return RecordingStatus.Stopped;
      default:
        return RecordingStatus.Unset;
    }
  }
}

/// Recording Object - represent a recording file
class Recording {
  /// File path
  String path;

  /// Extension
  String extension;

  /// Duration in milliseconds
  Duration duration;

  /// Audio format
  AudioFormat audioFormat;

  /// Metering
  AudioMetering metering;

  /// Is currently recording
  RecordingStatus status;
}

/// Audio Metering Level - describe the metering level of microphone when recording
class AudioMetering {
  /// Represent peak level of given short duration
  double peakPower;

  /// Represent average level of given short duration
  double averagePower;

  /// Is metering enabled in system
  bool isMeteringEnabled;

  AudioMetering({this.peakPower, this.averagePower, this.isMeteringEnabled});
}

/// Represent the status of a Recording
enum RecordingStatus {
  /// Recording not initialized
  Unset,

  /// Ready for start recording
  Initialized,

  /// Currently recording
  Recording,

  /// Currently Paused
  Paused,

  /// This specific recording Stopped, cannot be start again
  Stopped,
}

/// Audio Format,
/// WAV is lossless audio, recommended
enum AudioFormat {
  AAC,
  WAV,
}
