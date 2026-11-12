/// Event types of the replay stream.
class ReplayEventTypes {
  ReplayEventTypes._();

  static const tap = 'tap';
  static const longPress = 'long_press';
  static const drag = 'drag';
  static const scroll = 'scroll';
  static const navigation = 'navigation';
  static const textFocus = 'text_focus';
  static const textBlur = 'text_blur';
  static const textChange = 'text_change';
  static const keyboard = 'keyboard';
  static const viewport = 'viewport';
  static const lifecycle = 'lifecycle';
  static const screenshot = 'screenshot';
}

/// One entry of a replay chunk. Never contains text field values.
class ReplayEvent {
  const ReplayEvent(this.type, this.timestamp, [this.data = const {}]);

  final String type;
  final DateTime timestamp;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => {
        'type': type,
        'ts': timestamp.millisecondsSinceEpoch,
        ...data,
      };
}

/// Rounds a normalized coordinate to 4 decimals.
double normalized(double value, double extent) {
  if (extent <= 0) return 0;
  return (value / extent * 10000).round() / 10000;
}

/// Builds the JSON body of an `app.session_replay` record.
Map<String, Object?> buildReplayChunk({
  required String sessionId,
  required int sequence,
  required DateTime start,
  required DateTime end,
  required List<ReplayEvent> events,
  double? viewportWidth,
  double? viewportHeight,
}) =>
    {
      'version': 1,
      'session_id': sessionId,
      'sequence': sequence,
      'start_ts': start.millisecondsSinceEpoch,
      'end_ts': end.millisecondsSinceEpoch,
      if (viewportWidth != null && viewportHeight != null)
        'viewport': {
          'w': viewportWidth.round(),
          'h': viewportHeight.round(),
        },
      'events': [for (final e in events) e.toJson()],
    };
