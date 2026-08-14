import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import 'package:dio/dio.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:dramabox_free/data/models/drama_model.dart';
import 'package:dramabox_free/presentation/widgets/drama_details_sheet.dart';
import 'package:dramabox_free/data/models/episode_model.dart';
import 'package:dramabox_free/core/services/video_proxy_service.dart';
import 'package:dramabox_free/core/di/injection_container.dart' as di;
import 'package:dramabox_free/presentation/cubits/video_control_cubit.dart';
import 'package:dramabox_free/core/constants/app_enums.dart';
import 'package:dramabox_free/domain/repositories/drama_repository.dart';
import 'video_gesture_overlay.dart';

class SubtitleCaption {
  final int number;
  final Duration start;
  final Duration end;
  final String text;

  const SubtitleCaption({
    required this.number,
    required this.start,
    required this.end,
    required this.text,
  });
}

class VideoPlayerItem extends StatefulWidget {
  final EpisodeModel episode;
  final int index;
  final bool isVisible;
  final String dramaTitle;
  final VoidCallback onBack;
  final VoidCallback? onFinished;
  final VoidCallback? onWatched;
  final void Function(
    int position,
    int duration,
    bool isHistoryUpdate,
    bool isSubtitlesEnabled,
    String? subtitleLanguage,
  )?
  onProgress;
  final int initialPosition;
  final bool initialIsSubtitlesEnabled;
  final String? initialSubtitleLanguage;
  final DramaModel drama;
  final List<EpisodeModel> episodes;
  final Function(int) onEpisodeSelected;
  final AppContentProvider provider;

  const VideoPlayerItem({
    super.key,
    required this.episode,
    required this.index,
    required this.isVisible,
    required this.dramaTitle,
    required this.onBack,
    this.onFinished,
    this.onWatched,
    this.onProgress,
    this.initialPosition = 0,
    this.initialIsSubtitlesEnabled = true,
    this.initialSubtitleLanguage,
    required this.drama,
    required this.episodes,
    required this.onEpisodeSelected,
    required this.provider,
  });

  @override
  State<VideoPlayerItem> createState() => _VideoPlayerItemState();
}

class _VideoPlayerItemState extends State<VideoPlayerItem> {
  Player? _player;
  VideoController? _videoController;
  final List<StreamSubscription> _subscriptions = [];

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  bool _isPlaying = false;
  bool _isInitialized = false;
  bool _isInitializing = false;
  bool _hasError = false;
  String _errorMessage = '';
  bool _showUI = true;
  Timer? _hideTimer;
  bool _finishedTriggered = false;
  bool _watchedTriggered = false;
  int _lastReportedSecond = -1;

  // Subtitle state
  SubtitleModel? _selectedSubtitle;
  List<SubtitleCaption> _captions = [];
  String _currentCaption = '';
  bool _subtitlesEnabled = true;

  late VideoControlCubit _videoControlCubit;

  @override
  void initState() {
    super.initState();
    _videoControlCubit = VideoControlCubit();
    _subtitlesEnabled = widget.initialIsSubtitlesEnabled;
    _selectSubtitle();
    if (widget.isVisible) {
      _initializeController();
    }
    _startHideTimer();
  }

  void _selectSubtitle() {
    if (widget.episode.subtitles.isEmpty) return;

    if (widget.initialSubtitleLanguage != null) {
      _selectedSubtitle = widget.episode.subtitles.firstWhere(
        (s) => s.language == widget.initialSubtitleLanguage,
        orElse: () => _getDefaultSubtitle(),
      );
    } else {
      _selectedSubtitle = _getDefaultSubtitle();
    }

    if (_selectedSubtitle != null) {
      _loadSubtitles(_selectedSubtitle!.url);
    }
  }

  void _setupPlayerListeners(Player player) {
    _subscriptions.add(
      player.stream.position.listen((pos) {
        if (!mounted) return;
        setState(() {
          _position = pos;
        });
        _handlePlaybackProgress(pos, _duration);
      }),
    );

    _subscriptions.add(
      player.stream.duration.listen((dur) {
        if (!mounted) return;
        setState(() {
          _duration = dur;
        });
      }),
    );

    _subscriptions.add(
      player.stream.buffer.listen((buf) {
        if (!mounted) return;
        setState(() {
          _buffer = buf;
        });
      }),
    );

    _subscriptions.add(
      player.stream.playing.listen((playing) {
        if (!mounted) return;
        setState(() {
          _isPlaying = playing;
        });
      }),
    );

    _subscriptions.add(
      player.stream.completed.listen((completed) {
        if (completed && !_finishedTriggered) {
          _finishedTriggered = true;
          widget.onFinished?.call();
          if (widget.isVisible && !_watchedTriggered) {
            _watchedTriggered = true;
            widget.onWatched?.call();
          }
        }
      }),
    );

    _subscriptions.add(
      player.stream.error.listen((err) {
        debugPrint("Player error: $err");
        if (mounted) {
          setState(() {
            _hasError = true;
            _errorMessage = err.toString();
            _isInitializing = false;
          });
        }
      }),
    );
  }

  void _initializeController() async {
    if (_isInitializing) return;
    if (widget.episode.videoUrl.isEmpty) {
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = "Video URL is empty";
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isInitializing = true;
        _hasError = false;
        _errorMessage = '';
      });
    }

    try {
      String videoUrl = widget.episode.videoUrl;

      // Handle Dramabox decryption
      if (widget.provider == AppContentProvider.dramabox) {
        // Only decrypt if it's not already a decrypted stream URL
        if (!videoUrl.contains('api.sansekai.my.id')) {
          try {
            final decrypted = await di.sl<DramaRepository>().decryptVideoUrl(
              videoUrl,
            );
            if (decrypted.isNotEmpty && decrypted.startsWith('http')) {
              videoUrl = decrypted;
            } else {
              throw Exception(
                "Valid stream URL not received from decryption API",
              );
            }
          } catch (e) {
            debugPrint("Error decrypting video url: $e");
            if (mounted) {
              setState(() {
                _hasError = true;
                _errorMessage = 'Video decryption failed. Please try again.';
                _isInitializing = false;
              });
            }
            return;
          }
        }
      }

      // Proxy URLs
      videoUrl = di.sl<VideoProxyService>().getProxyUrl(videoUrl);

      // Check if we have a valid URL before proceeding
      if (videoUrl.isEmpty || !videoUrl.startsWith('http')) {
        throw Exception("Invalid video URL");
      }

      for (final sub in _subscriptions) {
        sub.cancel();
      }
      _subscriptions.clear();
      await _player?.dispose();

      final player = Player();
      _player = player;
      _videoController = VideoController(player);
      _setupPlayerListeners(player);

      await player.open(Media(videoUrl), play: widget.isVisible);

      if (widget.initialPosition > 0) {
        await player.seek(Duration(milliseconds: widget.initialPosition));
      }

      if (mounted) {
        setState(() {
          _isInitialized = true;
          _isInitializing = false;
        });
      }
    } catch (e) {
      debugPrint("Error initializing video: $e");
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = e.toString();
          _isInitializing = false;
        });
      }
    }
  }

  SubtitleModel _getDefaultSubtitle() {
    final List<String> enTags = ['en', 'english', 'eng', 'us', 'gb'];
    return widget.episode.subtitles.firstWhere(
      (s) => enTags.any((tag) => s.language.toLowerCase().contains(tag)),
      orElse: () => widget.episode.subtitles.firstWhere(
        (s) => !s.language.toLowerCase().contains('none') && s.url.isNotEmpty,
        orElse: () => widget.episode.subtitles.first,
      ),
    );
  }

  void _showSubtitleSelectionSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFF181818),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Subtitles',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Switch(
                        value: _subtitlesEnabled,
                        activeTrackColor: Colors.amber,
                        onChanged: (val) {
                          setState(() {
                            _subtitlesEnabled = val;
                          });
                          setModalState(() {});
                        },
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white24),
                  if (_subtitlesEnabled && widget.episode.subtitles.isNotEmpty)
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: widget.episode.subtitles.length,
                        itemBuilder: (context, idx) {
                          final sub = widget.episode.subtitles[idx];
                          final isSelected =
                              _selectedSubtitle?.language == sub.language;
                          return ListTile(
                            title: Text(
                              sub.language.toUpperCase(),
                              style: TextStyle(
                                color: isSelected ? Colors.amber : Colors.white,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            trailing: isSelected
                                ? const Icon(Icons.check, color: Colors.amber)
                                : null,
                            onTap: () {
                              setState(() {
                                _selectedSubtitle = sub;
                                _subtitlesEnabled = true;
                              });
                              _loadSubtitles(sub.url);
                              Navigator.pop(context);
                              _startHideTimer();
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _loadSubtitles(String url) async {
    try {
      final response = await Dio().get(url);
      if (response.data is String) {
        final content = response.data as String;
        _parseSubtitles(content);
      }
    } catch (e) {
      debugPrint("Error loading subtitles: $e");
    }
  }

  void _parseSubtitles(String content) {
    try {
      final lines = content.split('\n');
      final List<SubtitleCaption> captions = [];

      for (int i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.contains('-->')) {
          final times = line.split('-->');
          if (times.length == 2) {
            final startTimePart = times[0].trim();
            final endTimeLine = times[1].trim();
            final endTimePart = endTimeLine.split(' ')[0];

            final start = _parseSubtitleTime(startTimePart);
            final end = _parseSubtitleTime(endTimePart);

            String text = '';
            i++;
            while (i < lines.length && lines[i].trim().isNotEmpty) {
              if (i + 1 < lines.length && lines[i + 1].contains('-->')) {
                break;
              }

              if (text.isNotEmpty) text += '\n';
              text += lines[i].trim().replaceAll(
                RegExp(r'<[^>]*>'),
                '',
              );
              i++;
            }

            if (text.isNotEmpty && start != Duration.zero) {
              captions.add(
                SubtitleCaption(
                  number: captions.length,
                  start: start,
                  end: end,
                  text: text,
                ),
              );
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          _captions = captions;
        });
      }
    } catch (e) {
      debugPrint("Error parsing subtitles: $e");
    }
  }

  Duration _parseSubtitleTime(String time) {
    final timeClean = time.replaceAll(',', '.');
    final parts = timeClean.split(':');

    try {
      if (parts.length == 3) {
        final hours = int.parse(parts[0]);
        final minutes = int.parse(parts[1]);
        final secondsParts = parts[2].split('.');
        final seconds = int.parse(secondsParts[0]);
        final milliseconds = int.parse(
          secondsParts[1].padRight(3, '0').substring(0, 3),
        );
        return Duration(
          hours: hours,
          minutes: minutes,
          seconds: seconds,
          milliseconds: milliseconds,
        );
      } else if (parts.length == 2) {
        final minutes = int.parse(parts[0]);
        final secondsParts = parts[1].split('.');
        final seconds = int.parse(secondsParts[0]);
        final milliseconds = int.parse(
          secondsParts[1].padRight(3, '0').substring(0, 3),
        );
        return Duration(
          minutes: minutes,
          seconds: seconds,
          milliseconds: milliseconds,
        );
      }
    } catch (e) {
      debugPrint("Error parsing time part [$time]: $e");
    }
    return Duration.zero;
  }

  void _updateCurrentCaption(Duration position) {
    if (_captions.isEmpty || !_subtitlesEnabled) {
      if (_currentCaption.isNotEmpty) {
        setState(() => _currentCaption = '');
      }
      return;
    }

    final caption = _captions.firstWhere(
      (c) => position >= c.start && position <= c.end,
      orElse: () => const SubtitleCaption(
        number: -1,
        start: Duration.zero,
        end: Duration.zero,
        text: '',
      ),
    );

    if (_currentCaption != caption.text) {
      setState(() {
        _currentCaption = caption.text;
      });
    }
  }

  void _handlePlaybackProgress(Duration position, Duration duration) {
    _updateCurrentCaption(position);

    if (position >= duration &&
        duration != Duration.zero &&
        !_finishedTriggered) {
      _finishedTriggered = true;
      widget.onFinished?.call();
      if (widget.isVisible && !_watchedTriggered) {
        _watchedTriggered = true;
        widget.onWatched?.call();
      }
    }

    if (widget.isVisible && !_watchedTriggered) {
      final threshold = widget.index == 0 ? 10 : 3;
      if (position.inSeconds >= threshold) {
        _watchedTriggered = true;
        widget.onWatched?.call();
      }
    }

    // Process periodic progress updates
    if (widget.isVisible) {
      final currentSecond = position.inSeconds;
      if (currentSecond != _lastReportedSecond) {
        _lastReportedSecond = currentSecond;
        widget.onProgress?.call(
          position.inMilliseconds,
          duration.inMilliseconds,
          currentSecond % 2 == 0,
          _subtitlesEnabled,
          _selectedSubtitle?.language,
        );
      }
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        _videoControlCubit.setControlsVisible(false);
      }
    });
  }

  @override
  void didUpdateWidget(VideoPlayerItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.episode.videoUrl != widget.episode.videoUrl) {
      _isInitialized = false;
      _finishedTriggered = false;
      _watchedTriggered = false;
      for (final sub in _subscriptions) {
        sub.cancel();
      }
      _subscriptions.clear();
      _player?.dispose();
      _player = null;
      _videoController = null;
      _captions = [];
      _currentCaption = '';
      _selectSubtitle();
      if (widget.isVisible) {
        _initializeController();
      }
    } else if (widget.isVisible && !_isInitialized && !_isInitializing) {
      _initializeController();
    } else if (_isInitialized && _player != null) {
      if (widget.isVisible) {
        _player?.play();
      } else {
        _player?.pause();
      }
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _player?.dispose();
    _videoControlCubit.close();
    super.dispose();
  }

  void _seek(bool forward) async {
    if (!mounted || !_isInitialized || _player == null) return;
    final currentPosition = _position;
    final seekTo = forward
        ? currentPosition + const Duration(seconds: 3)
        : currentPosition - const Duration(seconds: 3);

    await _player?.seek(seekTo < Duration.zero ? Duration.zero : seekTo);
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  void _seekToPosition(double dx, double width, double durationMs) {
    if (width <= 0 || durationMs <= 0 || _player == null) return;
    final fraction = (dx / width).clamp(0.0, 1.0);
    final targetMs = (fraction * durationMs).round();
    _player?.seek(Duration(milliseconds: targetMs));
    _startHideTimer();
  }

  Widget _buildProgressIndicator() {
    final double durationMs = _duration.inMilliseconds.toDouble();
    final double positionMs = _position.inMilliseconds.toDouble().clamp(0.0, durationMs > 0 ? durationMs : 0.0);
    final double bufferMs = _buffer.inMilliseconds.toDouble().clamp(0.0, durationMs > 0 ? durationMs : 0.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final progressFraction = durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0;
        final bufferFraction = durationMs > 0 ? (bufferMs / durationMs).clamp(0.0, 1.0) : 0.0;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (details) {
            _seekToPosition(details.localPosition.dx, width, durationMs);
          },
          onHorizontalDragUpdate: (details) {
            _seekToPosition(details.localPosition.dx, width, durationMs);
          },
          onTapDown: (details) {
            _seekToPosition(details.localPosition.dx, width, durationMs);
          },
          child: SizedBox(
            height: 20,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                // Background track
                Container(
                  height: 4,
                  width: width,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Buffer bar
                Container(
                  height: 4,
                  width: width * bufferFraction,
                  decoration: BoxDecoration(
                    color: Colors.white38,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Played bar
                Container(
                  height: 4,
                  width: width * progressFraction,
                  decoration: BoxDecoration(
                    color: Colors.amber,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Thumb
                Positioned(
                  left: (width * progressFraction - 6).clamp(0.0, width - 12),
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: const BoxDecoration(
                      color: Colors.amber,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black45,
                          blurRadius: 4,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _videoControlCubit,
      child: BlocConsumer<VideoControlCubit, VideoControlState>(
        listener: (context, state) {
          if (_isInitialized && _player != null) {
            if (state.isSpeedUp) {
              _player!.setRate(1.5);
            } else {
              _player!.setRate(1.0);
            }

            if (state.seekAction != null) {
              _seek(state.seekAction == 'forward');
              Future.delayed(const Duration(milliseconds: 500), () {
                if (mounted) {
                  _videoControlCubit.clearSeek();
                }
              });
            }
          }

          if (state.areControlsVisible && !_showUI) {
            setState(() => _showUI = true);
            _startHideTimer();
          } else if (!state.areControlsVisible && _showUI) {
            setState(() => _showUI = false);
          }
        },
        builder: (context, state) {
          return Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              children: [
                // Background Thumbnail / First Frame
                if (!_isInitialized)
                  Positioned.fill(
                    child: CachedNetworkImage(
                      imageUrl: widget.episode.chapterImg,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Shimmer.fromColors(
                        baseColor: Colors.grey[900] ?? Colors.black87,
                        highlightColor: Colors.grey[800] ?? Colors.black54,
                        child: Container(color: Colors.black),
                      ),
                      errorWidget: (context, url, error) =>
                          Container(color: Colors.black),
                    ),
                  ),

                Center(
                  child: _isInitialized && _videoController != null
                      ? Video(
                          controller: _videoController!,
                          controls: NoVideoControls,
                          fill: Colors.black,
                        )
                      : const SizedBox(),
                ),

                // Subtitle Overlay
                if (_currentCaption.isNotEmpty && _subtitlesEnabled)
                  Positioned(
                    bottom: _showUI ? 220 : 160,
                    left: 32,
                    right: 32,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _currentCaption,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              height: 1.2,
                              shadows: [
                                Shadow(
                                  blurRadius: 4,
                                  color: Colors.black,
                                  offset: Offset(1, 1),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                // Loading indicator on top of thumbnail if not initialized and no error
                if (!_isInitialized && !_hasError)
                  const Center(
                    child: CircularProgressIndicator(color: Colors.white24),
                  ),

                // Error UI
                if (_hasError)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.error_outline,
                            color: Colors.white54,
                            size: 60,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _errorMessage,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70),
                          ),
                          const SizedBox(height: 20),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white24,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: _initializeController,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Layer 1: Background Toggle Layer (Handles taps on empty space)
                Positioned.fill(
                  child: VideoGestureOverlay(
                    videoControlCubit: _videoControlCubit,
                  ),
                ),

                // Visual Feedback for Speed Up
                if (state.isSpeedUp)
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 80,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.fast_forward_rounded,
                              color: Colors.amber,
                              size: 20,
                            ),
                            SizedBox(width: 8),
                            Text(
                              '1.5x Speed Playing',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // Visual Feedback for Seeking
                if (state.seekAction != null)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: const BoxDecoration(
                        color: Colors.black38,
                        shape: BoxShape.circle,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            state.seekAction == 'forward'
                                ? Icons.fast_forward_rounded
                                : Icons.fast_rewind_rounded,
                            color: Colors.white,
                            size: 40,
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            '3s',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Layer 2: UI Bars & Buttons
                // Top Bar (Back button + Episode Index)
                AnimatedOpacity(
                  opacity: _showUI ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: IgnorePointer(
                    ignoring: !_showUI,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8.0,
                        vertical: 8.0,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.2),
                        border: Border(
                          bottom: BorderSide(
                            color: Colors.white.withValues(alpha: 0.05),
                            width: 0.5,
                          ),
                        ),
                      ),
                      child: SafeArea(
                        bottom: false,
                        child: Row(
                          children: [
                            GestureDetector(
                              onTap: () {
                                widget.onBack();
                                _startHideTimer();
                              },
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.1),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.1),
                                    width: 0.5,
                                  ),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(20),
                                  child: BackdropFilter(
                                    filter: ImageFilter.blur(
                                      sigmaX: 10,
                                      sigmaY: 10,
                                    ),
                                    child: const Icon(
                                      Icons.arrow_back,
                                      color: Colors.white,
                                      size: 24,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Text(
                              'Ep. ${widget.index + 1} / ${widget.episodes.length} Episodes',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                letterSpacing: -0.5,
                              ),
                            ),
                            const Spacer(),
                            if (widget.episode.subtitles.isNotEmpty)
                              GestureDetector(
                                onTap: () {
                                  _showSubtitleSelectionSheet();
                                  _startHideTimer();
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _subtitlesEnabled
                                        ? Colors.amber.withValues(
                                            alpha: 0.9,
                                          )
                                        : Colors.white.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.1,
                                      ),
                                      width: 0.5,
                                    ),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(20),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _subtitlesEnabled
                                              ? Icons.closed_caption
                                              : Icons.closed_caption_disabled,
                                          color: _subtitlesEnabled
                                              ? Colors.black
                                              : Colors.white,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          _subtitlesEnabled &&
                                                  _selectedSubtitle != null
                                              ? _selectedSubtitle!.language
                                                  .toUpperCase()
                                              : 'CC',
                                          style: TextStyle(
                                            color: _subtitlesEnabled
                                                ? Colors.black
                                                : Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // Bottom UI (Drama Info and Progress Indicator)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedOpacity(
                    opacity: _showUI ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 300),
                    child: IgnorePointer(
                      ignoring: !_showUI,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.8),
                              Colors.black.withValues(alpha: 0.4),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: SafeArea(
                          top: false,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 12),
                              // Controls Row: Play/Pause + Duration
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16.0,
                                ),
                                child: Row(
                                  children: [
                                    if (_isInitialized && _player != null)
                                      GestureDetector(
                                        onTap: () {
                                          _player?.playOrPause();
                                          _startHideTimer();
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.all(4),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withValues(
                                              alpha: 0.1,
                                            ),
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white.withValues(
                                                alpha: 0.1,
                                              ),
                                              width: 0.5,
                                            ),
                                          ),
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              20,
                                            ),
                                            child: BackdropFilter(
                                              filter: ImageFilter.blur(
                                                sigmaX: 10,
                                                sigmaY: 10,
                                              ),
                                              child: Icon(
                                                _isPlaying
                                                    ? Icons.pause_rounded
                                                    : Icons.play_arrow_rounded,
                                                color: Colors.white,
                                                size: 32,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    const SizedBox(width: 12),
                                    if (_isInitialized && _player != null)
                                      Text(
                                        '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          fontFeatures: [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                    const Spacer(),
                                    GestureDetector(
                                      onTap: () {
                                        showModalBottomSheet(
                                          context: context,
                                          isScrollControlled: true,
                                          useSafeArea: true,
                                          backgroundColor: Colors.transparent,
                                          builder: (context) =>
                                              DramaDetailsSheet(
                                                drama: widget.drama,
                                                episodes: widget.episodes,
                                                currentIndex: widget.index,
                                                onEpisodeSelected:
                                                    widget.onEpisodeSelected,
                                              ),
                                        );
                                        _startHideTimer();
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.1,
                                          ),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: Colors.white.withValues(
                                              alpha: 0.15,
                                            ),
                                            width: 1,
                                          ),
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                          child: BackdropFilter(
                                            filter: ImageFilter.blur(
                                              sigmaX: 10,
                                              sigmaY: 10,
                                            ),
                                            child: const Icon(
                                              Icons
                                                  .format_list_bulleted_rounded,
                                              color: Colors.white,
                                              size: 20,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),

                              if (_isInitialized && _player != null)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16.0,
                                  ),
                                  child: _buildProgressIndicator(),
                                )
                              else
                                const SizedBox(height: 4),

                              const SizedBox(height: 16),

                              // Drama Title & Episode Info
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16.0,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      widget.dramaTitle,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        shadows: [
                                          Shadow(
                                            blurRadius: 10,
                                            color: Colors.black,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
