import 'package:flutter_test/flutter_test.dart';
import 'package:turbonotes/services/text_merge.dart';

void main() {
  test('unchanged and identical sides preserve the exact source', () {
    const source = '# Title\r\n\r\n-  item  \r\nlast';
    expect(mergeNoteText(source, source, '$source!'), '$source!');
    expect(mergeNoteText(source, '$source!', source), '$source!');
    expect(mergeNoteText(null, source, source), source);
  });

  test('independent replacements and additions merge without reformatting', () {
    expect(mergeNoteText('a\nb\nc\n', 'A\nb\nc\n', 'a\nb\nC\n'), 'A\nb\nC\n');
    expect(
      mergeNoteText('a\nb\nc', 'intro\na\nb\nc', 'a\nb\nc\nend'),
      'intro\na\nb\nc\nend',
    );
    expect(
      mergeNoteText('a\r\nb\r\nc', 'A\r\nb\r\nc', 'a\r\nb\r\nC'),
      'A\r\nb\r\nC',
    );
    expect(
      mergeNoteText('a\nb\nc\nd\n', 'a\nc\nd\n', 'a\nb\nc\nD\n'),
      'a\nc\nD\n',
    );
  });

  test(
    'overlapping changes, insertions and unknown ancestry are conflicts',
    () {
      expect(mergeNoteText('a\nb\n', 'a\nours\n', 'a\ntheirs\n'), isNull);
      expect(mergeNoteText('a\n', 'a\nours\n', 'a\ntheirs\n'), isNull);
      expect(mergeNoteText('a\nb\n', 'a\n', 'a\nB\n'), isNull);
      expect(mergeNoteText(null, 'ours', 'theirs'), isNull);
      expect(mergeNoteText('', 'ours', 'theirs'), isNull);
    },
  );

  test('a shared change and a separate change are applied once', () {
    expect(
      mergeNoteText('a\nb\nc\nd\n', 'A\nb\nc\nd\n', 'A\nb\nc\nD\n'),
      'A\nb\nc\nD\n',
    );
  });

  test('large unrelated changes fall back to a conflict', () {
    final base = List.generate(1600, (i) => 'base $i\n').join();
    final ours = List.generate(1600, (i) => 'ours $i\n').join();
    final theirs = List.generate(1600, (i) => 'theirs $i\n').join();
    expect(mergeNoteText(base, ours, theirs), isNull);
  });
}
