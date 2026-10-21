import 'package:bao_agent/src/permissions/approval_risk.dart';
import 'package:flutter_test/flutter_test.dart';

/// What an approval says before the user says yes.
void main() {
  test('a read only call is read', () {
    expect(
      approvalRiskFor('Read', {'file_path': 'a.txt'}).risk,
      ApprovalRisk.read,
    );
    expect(
      approvalRiskFor('Bash', {'command': 'git status'}).risk,
      ApprovalRisk.read,
    );
  });

  test('an edit is a reversible write', () {
    final risk = approvalRiskFor('Write', {'file_path': 'a.txt'});
    expect(risk.risk, ApprovalRisk.write);
    expect(risk.reversible, isTrue);
  });

  test('a command that cannot be undone says so', () {
    final risk = approvalRiskFor('Bash', {'command': 'rm -rf build'});
    expect(risk.risk, ApprovalRisk.destructive);
    expect(risk.reversible, isFalse);
  });

  test('a command that touches a credential says so', () {
    final risk = approvalRiskFor('Bash', {'command': 'cat ~/.ssh/id_rsa'});
    expect(risk.risk, ApprovalRisk.credential);
    expect(risk.reversible, isFalse);
  });

  test('a command that reaches the network says so', () {
    expect(
      approvalRiskFor('Bash', {'command': 'curl https://x'}).risk,
      ApprovalRisk.network,
    );
    expect(
      approvalRiskFor('WebFetch', {'url': 'https://x'}).risk,
      ApprovalRisk.network,
    );
  });

  test('an MCP tool is a write unless its name says network', () {
    final write = approvalRiskFor('mcp__server__create_issue', {});
    expect(write.risk, ApprovalRisk.write);
    expect(write.source, 'mcp');
    final network = approvalRiskFor('mcp__baocode__browser_evaluate', {});
    expect(network.risk, ApprovalRisk.network);
    expect(network.source, 'sdk');
    final cookie = approvalRiskFor(
      'mcp__baocode__browser_evaluate',
      {'expression': 'document.cookie'},
    );
    expect(cookie.risk, ApprovalRisk.credential);
    expect(cookie.reversible, isFalse);
  });
}
