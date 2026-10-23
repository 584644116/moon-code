import 'package:baocode/chat/chat_feed.dart';
import 'package:baocode/chat/chat_find.dart';
import 'package:baocode/chat/chat_history_view.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer_draft.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Feed extends ChangeNotifier implements ChatFeed {
  _Feed(this.items);

  List<ChatItem> items;
  bool streaming = true;

  @override
  int get itemCount => items.length;
  @override
  ChatItem itemAt(int index) => items[index];
  @override
  bool get isStreaming => streaming;
  @override
  bool get isUnprompted => false;
  @override
  bool get canEditMessages => false;
  @override
  ({int index, ComposerDraft draft})? get editing => null;
  @override
  set editing(({int index, ComposerDraft draft})? value) {}
  @override
  void editMessage(int index, ComposerMessage message) {}
  @override
  VoidCallback? moveToBackgroundAt(int index) => null;
  @override
  VoidCallback? stopAt(int index) => null;
}

void main() {
  testWidgets('a row whose item did not change is not built again', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final feed = _Feed([
      const UserMessageItem(text: 'Question'),
      for (var i = 0; i < 20; i++)
        ToolCallItem(kind: ToolKind.read, target: 'f$i.dart'),
      const AssistantTextItem('Answer'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: ChatHistoryView(feed: feed)),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    var rebuilt = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is ChatFindRow) rebuilt++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    // The answer streams: only its own row is new.
    feed.items[feed.items.length - 1] = const AssistantTextItem('Answer, ');
    feed.notifyListeners();
    await tester.pump();

    expect(rebuilt, lessThan(3), reason: 'not every row');
  });

  testWidgets('a row whose text changed is built again', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final feed = _Feed([
      const UserMessageItem(text: 'Question'),
      const ToolCallItem(kind: ToolKind.read, target: 'a.dart'),
      const AssistantTextItem('Answer'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: ChatHistoryView(feed: feed)),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    var rebuilt = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is ChatFindRow) rebuilt++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    feed.items[2] = const AssistantTextItem('Answer, then more.');
    feed.notifyListeners();
    await tester.pump();

    expect(rebuilt, 1, reason: 'the row it is, and no other');
  });
}
