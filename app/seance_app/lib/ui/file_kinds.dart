import 'package:flutter/material.dart';
import 'package:seance_core/seance_core.dart';

import '../family_hues.dart';

/// A listed item's kind, for its glyph only: the Files tab names an
/// item by its file type in words, so a wrong guess from an extension
/// never misleads assistive tech.
///
/// Ported from Poltergeist's `ui/panes/pane_format.dart` (the
/// classifier) and `ui/panes/kind_glyph.dart` (the glyphs) with its
/// D34 colour vocabulary, so a folder, a photo or a script reads the
/// same in both apps. Keep the tables in step.
enum FileKind {
  folder,
  link,
  image,
  document,
  code,
  archive,
  pdf,
  audio,
  video,
  other,
}

// Extension families, lowercase, one space-separated table per family:
// machine data the classifier splits once, never rendered.
const _imageExtensions =
    'png jpg jpeg gif webp bmp tif tiff heic heif svg ico avif psd raw';
const _documentExtensions =
    'txt md markdown rst log csv tsv rtf doc docx odt pages xls xlsx ods '
    'numbers ppt pptx odp epub';
const _codeExtensions =
    'json yaml yml toml xml html htm css scss js mjs ts jsx tsx dart py rb '
    'go rs java kt swift c h cc cpp hpp';
const _scriptExtensions =
    'm mm cs php sh bash zsh fish ps1 bat sql ini conf cfg env lock';
const _archiveExtensions =
    'zip tar gz tgz bz2 xz 7z rar zst lz4 dmg iso deb rpm pkg jar apk';
const _audioExtensions = 'mp3 wav flac aac ogg m4a opus';
const _videoExtensions = 'mp4 mov mkv avi webm m4v wmv mpg';

Set<String> _extensionSet(List<String> tables) => {
  for (final table in tables) ...table.split(' '),
};

final _kindByExtension = <String, FileKind>{
  for (final ext in _extensionSet([_imageExtensions])) ext: FileKind.image,
  for (final ext in _extensionSet([_documentExtensions]))
    ext: FileKind.document,
  for (final ext in _extensionSet([_codeExtensions, _scriptExtensions]))
    ext: FileKind.code,
  for (final ext in _extensionSet([_archiveExtensions]))
    ext: FileKind.archive,
  for (final ext in _extensionSet([_audioExtensions])) ext: FileKind.audio,
  for (final ext in _extensionSet([_videoExtensions])) ext: FileKind.video,
  'pdf': FileKind.pdf,
};

/// [entry]'s kind: its file type first (folders and links are never
/// guessed from a name), then the lowercase extension after the last
/// dot. A leading dot is part of a dotfile's stem, so `.bashrc` has no
/// extension and reads as a generic file.
FileKind fileKind(RemoteFileEntry entry) {
  switch (entry.type) {
    case RemoteFileType.directory:
      return FileKind.folder;
    case RemoteFileType.symbolicLink:
      return FileKind.link;
    case RemoteFileType.file || RemoteFileType.other:
      break;
  }
  final name = entry.name;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return FileKind.other;
  return _kindByExtension[name.substring(dot + 1).toLowerCase()] ??
      FileKind.other;
}

/// [kind]'s glyph and family hue. The glyphs are the filled faces,
/// since a hairline outline at list size carries too little colour to
/// be told apart at a glance.
(IconData, FamilyHue) fileKindGlyph(FileKind kind) => switch (kind) {
  FileKind.folder => (Icons.folder, FamilyHue.blue),
  FileKind.link => (Icons.shortcut, FamilyHue.cyan),
  FileKind.image => (Icons.image, FamilyHue.pink),
  FileKind.document => (Icons.description, FamilyHue.graphite),
  FileKind.code => (Icons.integration_instructions, FamilyHue.orange),
  FileKind.archive => (Icons.inventory_2, FamilyHue.brown),
  FileKind.pdf => (Icons.picture_as_pdf, FamilyHue.red),
  FileKind.audio => (Icons.audio_file, FamilyHue.purple),
  FileKind.video => (Icons.video_file, FamilyHue.purple),
  FileKind.other => (Icons.insert_drive_file, FamilyHue.graphite),
};

/// [entry]'s kind glyph as an [Icon] in its hue for [context]'s theme.
Icon fileKindIcon(BuildContext context, RemoteFileEntry entry, {double? size}) {
  final (glyph, hue) = fileKindGlyph(fileKind(entry));
  return Icon(glyph, size: size, color: FamilyPalette.of(context).glyph(hue));
}
