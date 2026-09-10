import 'sleep_window.dart';

/// Web (and any platform without dart:io) has no FFI, so no YAMNet. Returning
/// null rather than throwing lets the recorder degrade exactly like it did
/// before the classifier existed: the night is still uploaded as one
/// light-sleep block, because duration is what the debt window needs.
Future<SleepAudioClassifier?> createSleepAudioClassifier() async => null;
