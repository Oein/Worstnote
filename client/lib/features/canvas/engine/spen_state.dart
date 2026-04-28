import 'package:flutter_riverpod/flutter_riverpod.dart';

/// True while the Samsung S-Pen side button is physically held down.
/// Set by the editor via spen_remote SDK; read by CanvasView.
final spenButtonHeldProvider = StateProvider<bool>((ref) => false);
