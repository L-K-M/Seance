import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/family_hues.dart';
import 'package:seance_app/ui/file_kinds.dart';
import 'package:seance_core/seance_core.dart';

/// The Files tab's kind table, ported from Poltergeist so a folder, a
/// photo or a script reads the same in both apps (its D34).
void main() {
  RemoteFileEntry entry(
    String name, [
    RemoteFileType type = RemoteFileType.file,
  ]) => RemoteFileEntry(path: '/x/$name', name: name, type: type);

  test('the file type wins over any extension', () {
    expect(fileKind(entry('photos.png', RemoteFileType.directory)),
        FileKind.folder);
    expect(fileKind(entry('latest.zip', RemoteFileType.symbolicLink)),
        FileKind.link);
  });

  test('extensions map to their family, case-insensitively', () {
    expect(fileKind(entry('IMG_0001.JPG')), FileKind.image);
    expect(fileKind(entry('main.dart')), FileKind.code);
    expect(fileKind(entry('deploy.sh')), FileKind.code);
    expect(fileKind(entry('notes.md')), FileKind.document);
    expect(fileKind(entry('Report.DOCX')), FileKind.document);
    expect(fileKind(entry('site.tar.gz')), FileKind.archive);
    expect(fileKind(entry('manual.pdf')), FileKind.pdf);
    expect(fileKind(entry('talk.mp4')), FileKind.video);
    expect(fileKind(entry('song.flac')), FileKind.audio);
    expect(fileKind(entry('data.bin')), FileKind.other);
  });

  test('dotfiles and bare names have no extension', () {
    expect(fileKind(entry('.bashrc')), FileKind.other);
    expect(fileKind(entry('Makefile')), FileKind.other);
    expect(fileKind(entry('trailing.')), FileKind.other);
    expect(fileKind(entry('.config.json')), FileKind.code);
  });

  test('each kind wears its family hue, and no two share a glyph', () {
    expect({for (final kind in FileKind.values) kind: fileKindGlyph(kind).$2}, {
      FileKind.folder: FamilyHue.blue,
      FileKind.link: FamilyHue.cyan,
      FileKind.image: FamilyHue.pink,
      FileKind.document: FamilyHue.graphite,
      FileKind.code: FamilyHue.orange,
      FileKind.archive: FamilyHue.brown,
      FileKind.pdf: FamilyHue.red,
      FileKind.audio: FamilyHue.purple,
      FileKind.video: FamilyHue.purple,
      FileKind.other: FamilyHue.graphite,
    });
    expect(
      {for (final kind in FileKind.values) fileKindGlyph(kind).$1},
      hasLength(FileKind.values.length),
    );
    expect(fileKindGlyph(FileKind.folder).$1, Icons.folder);
  });
}
