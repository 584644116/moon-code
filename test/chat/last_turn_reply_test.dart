import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/mock_conversation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The mock history is a turn of eight items: a message at 0, thinking and
  // tools after it, the agent's own text at 4 and 7.
  String said(int index) =>
      (MockConversation.itemAt(index) as AssistantTextItem).text.trim();

  test('the last turn\'s texts, in order, joined', () {
    // Two turns: the second runs 8..15, its texts at 12 and 15.
    final session = ChatSession(historyCount: 16);
    addTearDown(session.dispose);
    expect(session.lastTurnReply, [said(12), said(15)].join('\n\n'));
  });

  test('the message sent stops it: the turn before is not in it', () {
    // One turn and a half: it ends on the second turn's first text, at 12.
    final session = ChatSession(historyCount: 13);
    addTearDown(session.dispose);
    // Exactly one text, so the scan stopped at the message before it rather
    // than reading on into the turn before that.
    expect(session.lastTurnReply, said(12));
    expect(session.lastTurnReply, isNot(contains(said(15))));
  });

  test('nothing said: no history, no reply', () {
    final session = ChatSession(historyCount: 0);
    addTearDown(session.dispose);
    expect(session.lastTurnReply, isNull);
  });
}
