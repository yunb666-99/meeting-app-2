import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import '../../../core/constants.dart';
import '../../../data/api_client.dart';
import '../../../data/repositories/meeting_repository.dart';
import '../../../data/services/livekit_service.dart';
import '../../../data/services/chat_service.dart';
import '../../../data/models/chat_message.dart';
import '../providers/meeting_provider.dart';
import '../widgets/participant_grid.dart';
import '../widgets/control_bar.dart';
import '../widgets/chat_panel.dart';
import '../widgets/meeting_info_dialog.dart';

class MeetingScreen extends ConsumerStatefulWidget {
  final String meetingId;
  final bool isGuest;
  final String guestNickname;

  const MeetingScreen({
    super.key,
    required this.meetingId,
    this.isGuest = false,
    this.guestNickname = '',
  });

  @override
  ConsumerState<MeetingScreen> createState() => _MeetingScreenState();
}

class _MeetingScreenState extends ConsumerState<MeetingScreen>
    with WidgetsBindingObserver {
  final LivekitService _livekitService = LivekitService();
  final ChatService _chatService = ChatService();
  final MeetingRepository _meetingRepository = MeetingRepository();
  final ApiClient _apiClient = ApiClient();

  final List<ChatMessage> _chatMessages = [];
  StreamSubscription? _chatSub;
  StreamSubscription? _joinedSub;
  StreamSubscription? _leftSub;
  StreamSubscription? _endedSub;
  StreamSubscription? _kickedSub;

  bool _isInitialized = false;
  bool _isConnecting = true;
  String? _connectionError;
  String? _livekitUrl;
  String? _livekitToken;
  String? _currentIdentity;
  bool _isHost = false;

  Timer? _timer;
  Duration _callDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initMeeting();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _chatSub?.cancel();
    _joinedSub?.cancel();
    _leftSub?.cancel();
    _endedSub?.cancel();
    _kickedSub?.cancel();
    _livekitService.disconnect();
    _chatService.disconnect();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _livekitService.toggleCamera(false);
    } else if (state == AppLifecycleState.resumed) {
      final meetingState = ref.read(meetingProvider);
      if (meetingState.cameraEnabled) {
        _livekitService.toggleCamera(true);
      }
    }
  }

  Future<void> _initMeeting() async {
    setState(() {
      _isConnecting = true;
      _connectionError = null;
    });

    try {
      // 1. 获取 LiveKit Token
      final tokenData =
          await _meetingRepository.getMeetingToken(widget.meetingId);
      _livekitToken = tokenData['livekitToken']!;
      _livekitUrl = tokenData['livekitUrl']!;

      // 2. 连接 LiveKit 房间
      final room =
          await _livekitService.connect(_livekitUrl!, _livekitToken!);

      // 3. 获取本地参与者信�?      final localParticipant = room.localParticipant;
      _currentIdentity = localParticipant?.identity ?? '';
      final userName =
          localParticipant?.name ?? widget.guestNickname;

      // 4. 设置初始媒体状�?      await _livekitService.toggleCamera(true);
      await _livekitService.toggleMicrophone(true);

      // 5. 获取会议详情，判断是否是主持�?      try {
        final meeting =
            await _meetingRepository.getMeeting(widget.meetingId);
        final currentUser = ref.read(currentUserProvider);
        final host = meeting.hostId == currentUser?.id;
        _isHost = host;
        ref
            .read(meetingProvider.notifier)
            .setMeeting(meeting, host || widget.isGuest == false);
      } catch (_) {
        // 会议详情获取失败不阻塞入�?      }

      // 6. 连接聊天 WebSocket
      final accessToken = await _apiClient.getAccessToken();
      final token = accessToken ?? _livekitToken ?? '';

      _chatService.connect(
        AppConstants.wsUrl,
        token,
        widget.meetingId,
      );

      // 7. 设置事件监听
      _setupLiveKitListeners(room);
      _setupChatListeners();

      // 8. 添加本地参与�?      ref.read(meetingProvider.notifier).addParticipant(
            Participant(
              identity: _currentIdentity!,
              name: userName,
              isCameraOn: true,
              isMicOn: true,
              isHost: _isHost,
            ),
          );

      // 9. 添加已有的远程参与�?      for (final rp in room.remoteParticipants.values) {
        final identity = rp.identity ?? '';
        if (identity.isNotEmpty) {
          ref.read(meetingProvider.notifier).addParticipant(
                Participant(
                  identity: identity,
                  name: rp.name ?? '未知用户',
                  isCameraOn: rp.isCameraEnabled()(),
                  isMicOn: rp.isMicrophoneEnabled()(),
                  isScreenSharing: rp.isScreenShareEnabled()(),
                ),
              );
        }
      }

      // 10. 启动计时�?      _startTimer();

      setState(() {
        _isInitialized = true;
        _isConnecting = false;
      });
    } catch (e) {
      setState(() {
        _isConnecting = false;
        _connectionError =
            e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _setupLiveKitListeners(lk.Room room) {
    room.events.listen((event) {
      if (event is lk.ParticipantConnectedEvent) {
        final p = event.participant;
        final identity = p.identity ?? '';
        if (identity.isNotEmpty) {
          ref.read(meetingProvider.notifier).addParticipant(
                Participant(
                  identity: identity,
                  name: p.name ?? '未知用户',
                  isCameraOn: p.isCameraEnabled(),
                  isMicOn: p.isMicrophoneEnabled(),
                  isScreenSharing: p.isScreenShareEnabled(),
                ),
              );
        }
      } else if (event is lk.ParticipantDisconnectedEvent) {
        ref
            .read(meetingProvider.notifier)
            .removeParticipant(event.participant.identity ?? '');
      } else if (event is lk.TrackPublishedEvent) {
        _syncTrackState(event.participant);
      } else if (event is lk.TrackUnpublishedEvent) {
        _syncTrackState(event.participant);
      }
    });
  }

  void _syncTrackState(lk.Participant participant) {
    final identity = participant.identity ?? '';
    if (identity.isEmpty) return;
    ref.read(meetingProvider.notifier).updateParticipant(
          identity,
          isCameraOn: participant.isCameraEnabled(),
          isMicOn: participant.isMicrophoneEnabled(),
          isScreenSharing: participant.isScreenShareEnabled(),
        );
  }

  void _setupChatListeners() {
    _chatSub = _chatService.onMessage.listen((data) {
      final msg = ChatMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        meetingId: widget.meetingId,
        senderName: data['senderName']?.toString() ?? '',
        senderRole: data['senderRole']?.toString() ?? 'USER',
        content: data['content']?.toString() ?? '',
        messageType: data['messageType']?.toString() ?? 'TEXT',
        createdAt: DateTime.now().toIso8601String(),
      );
      setState(() => _chatMessages.add(msg));
    });

    _joinedSub = _chatService.onParticipantJoined.listen((data) {
      final msg = ChatMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        meetingId: widget.meetingId,
        senderName: '系统',
        senderRole: 'SYSTEM',
        content: '${data['name'] ?? '有人'} 加入了会�?,
        messageType: 'SYSTEM',
        createdAt: DateTime.now().toIso8601String(),
      );
      setState(() => _chatMessages.add(msg));
    });

    _leftSub = _chatService.onParticipantLeft.listen((data) {
      final msg = ChatMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        meetingId: widget.meetingId,
        senderName: '系统',
        senderRole: 'SYSTEM',
        content: '${data['name'] ?? '有人'} 离开了会�?,
        messageType: 'SYSTEM',
        createdAt: DateTime.now().toIso8601String(),
      );
      setState(() => _chatMessages.add(msg));
    });

    _endedSub = _chatService.onMeetingEnded.listen((_) {
      _leaveMeeting(reason: '会议已结�?);
    });

    _kickedSub = _chatService.onKicked.listen((_) {
      _leaveMeeting(reason: '您已被移出会�?);
    });
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _callDuration += const Duration(seconds: 1);
        });
      }
    });
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  void _leaveMeeting({String? reason}) {
    _timer?.cancel();
    _livekitService.disconnect();
    _chatService.disconnect();
    ref.read(meetingProvider.notifier).reset();

    if (mounted) {
      if (reason != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(reason),
            backgroundColor: const Color(AppColors.warning),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
        );
      }
      context.pop();
    }
  }

  Future<void> _toggleMic() async {
    final meetingState = ref.read(meetingProvider);
    final newValue = !meetingState.micEnabled;
    ref.read(meetingProvider.notifier).toggleMic();
    await _livekitService.toggleMicrophone(newValue);
  }

  Future<void> _toggleCamera() async {
    final meetingState = ref.read(meetingProvider);
    final newValue = !meetingState.cameraEnabled;
    ref.read(meetingProvider.notifier).toggleCamera();
    await _livekitService.toggleCamera(newValue);
  }

  Future<void> _toggleScreenShare() async {
    final meetingState = ref.read(meetingProvider);
    if (meetingState.isScreenSharing) {
      await _livekitService.stopScreenShare();
      ref.read(meetingProvider.notifier).setScreenSharing(false);
    } else {
      await _livekitService.startScreenShare();
      ref.read(meetingProvider.notifier).setScreenSharing(true);
    }
  }

  void _toggleChat() {
    ref.read(meetingProvider.notifier).toggleChat();
  }

  void _showMeetingInfo() {
    final meeting = ref.read(meetingProvider).meeting;
    if (meeting == null) return;

    showDialog(
      context: context,
      builder: (ctx) => MeetingInfoDialog(
        meetingId: meeting.meetingId,
        password: meeting.password,
      ),
    );
  }

  void _sendChatMessage(String content) {
    if (content.trim().isEmpty) return;
    _chatService.sendMessage(widget.meetingId, content.trim());
  }

  Future<void> _handleHostAction(String action) async {
    try {
      switch (action) {
        case 'mute_all':
          await _meetingRepository.muteAll(widget.meetingId);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('已全体静�?),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          break;
        case 'end_meeting':
          final confirm = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('确认'),
              content: const Text('确定要结束会议吗�?),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('确定',
                      style:
                          TextStyle(color: Color(AppColors.error))),
                ),
              ],
            ),
          );
          if (confirm == true) {
            await _meetingRepository.endMeeting(widget.meetingId);
            _leaveMeeting(reason: '您已结束会议');
          }
          break;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: const Color(AppColors.error),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final meetingState = ref.watch(meetingProvider);

    // 连接中状�?    if (_isConnecting) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 24),
              const Text(
                '正在连接会议...',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                '会议�? ${widget.meetingId}',
                style:
                    const TextStyle(color: Colors.white54, fontSize: 14),
              ),
              if (_connectionError != null) ...[
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    _connectionError!,
                    style: const TextStyle(
                        color: Colors.redAccent, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _initMeeting,
                  child: const Text('重试'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => context.pop(),
                  child: const Text('返回',
                      style: TextStyle(color: Colors.white70)),
                ),
              ],
            ],
          ),
        ),
      );
    }

    // 已连�?- 正常会议界面
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _leaveMeeting();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1A2E),
        appBar: AppBar(
          backgroundColor: const Color(0xFF252540),
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                meetingState.meeting?.title ?? '会议',
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(AppColors.primaryBlue)
                      .withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _formatDuration(_callDuration),
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(AppColors.primaryLight),
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
          actions: [
            if (_isHost)
              IconButton(
                icon: const Icon(Icons.info_outline),
                tooltip: '会议信息',
                onPressed: _showMeetingInfo,
              ),
            // 参会人数
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.people, size: 16, color: Colors.white70),
                    const SizedBox(width: 4),
                    Text(
                      '${meetingState.participants.length}',
                      style: const TextStyle(
                          fontSize: 13, color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        body: Stack(
          children: [
            // 主视频区�?            Column(
              children: [
                Expanded(
                  child: _buildVideoArea(meetingState),
                ),
                // 底部控制�?                ControlBar(
                  isMicOn: meetingState.micEnabled,
                  isCameraOn: meetingState.cameraEnabled,
                  isScreenSharing: meetingState.isScreenSharing,
                  isHost: _isHost,
                  onMicTap: _toggleMic,
                  onCameraTap: _toggleCamera,
                  onScreenShareTap: _toggleScreenShare,
                  onChatTap: _toggleChat,
                  onLeaveTap: () => _leaveMeeting(),
                  onHostAction: _handleHostAction,
                  participants: meetingState.participants,
                  currentIdentity: _currentIdentity ?? '',
                  onKickParticipant: (identity) async {
                    try {
                      await _meetingRepository.kickParticipant(
                          widget.meetingId, identity);
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(e
                                .toString()
                                .replaceFirst('Exception: ', '')),
                            backgroundColor:
                                const Color(AppColors.error),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    }
                  },
                ),
              ],
            ),

            // 聊天面板（滑出覆盖半屏）
            if (meetingState.isChatVisible)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                top: MediaQuery.of(context).size.height * 0.08,
                child: ChatPanel(
                  messages: _chatMessages,
                  currentIdentity: _currentIdentity ?? '',
                  onSendMessage: _sendChatMessage,
                  onClose: _toggleChat,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoArea(MeetingState meetingState) {
    if (meetingState.hasScreenShare && meetingState.screenShareParticipant != null) {
      final screenParticipant = meetingState.screenShareParticipant!;
      return Column(
        children: [
          // 屏幕共享大画�?          Expanded(
            flex: 3,
            child: Container(
              color: Colors.black,
              child: _buildScreenShareView(screenParticipant),
            ),
          ),
          // 参与者小画面�?          SizedBox(
            height: 110,
            child: ParticipantGrid(
              participants: meetingState.participants,
              localIdentity: _currentIdentity ?? '',
              isScreenShareMode: true,
              columnCount: meetingState.participants.length,
            ),
          ),
        ],
      );
    }

    // 普通网格布局
    return ParticipantGrid(
      participants: meetingState.participants,
      localIdentity: _currentIdentity ?? '',
      isScreenShareMode: false,
    );
  }

  Widget _buildScreenShareView(Participant participant) {
    final room = _livekitService.currentRoom;
    if (room == null) {
      return const Center(
        child:
            Icon(Icons.screen_share, color: Colors.white38, size: 48),
      );
    }

    // 查找参与者的屏幕共享轨道
    if (participant.identity == _currentIdentity) {
      // 本地屏幕共享
      final localParticipant = room.localParticipant;
      if (localParticipant != null) {
        for (final pub in localParticipant.videoTrackPublications) {
          if (pub.isScreenShare && pub.track != null) {
            return lk.VideoTrackRenderer(
              pub.track!,
              fit: RenderingFit.contain,
            );
          }
        }
      }
    } else {
      // 远程参与者屏幕共�?      for (final rp in room.remoteParticipants.values) {
        if (rp.identity == participant.identity) {
          for (final pub in rp.videoTrackPublications) {
            if (pub.isScreenShare && pub.track != null) {
              return lk.VideoTrackRenderer(
                pub.track!,
                fit: RenderingFit.contain,
              );
            }
          }
        }
      }
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.screen_share,
              color: Colors.white38, size: 48),
          const SizedBox(height: 8),
          Text(
            '${participant.name} 正在共享屏幕',
            style: const TextStyle(color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

