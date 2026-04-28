// Centralized ID generator. Uses UUID v7 (time-ordered) so server indexes
// stay roughly insertion-ordered and sync deltas land in a sensible order.

import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Generates a new UUID v7 (time-ordered).
String newId() => _uuid.v7();
