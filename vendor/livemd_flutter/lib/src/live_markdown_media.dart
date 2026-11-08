/// The presentation to use for a Markdown media reference.
enum LiveMarkdownMediaType { image, video, audio }

/// Resolves application-owned attachment metadata. Return null to use the
/// conventional filename-extension fallback. Persist this metadata alongside
/// the document if references do not contain a recognizable extension.
typedef LiveMarkdownMediaTypeResolver = LiveMarkdownMediaType? Function(
  String destination,
);

LiveMarkdownMediaType resolveLiveMarkdownMediaType(
  String destination, {
  LiveMarkdownMediaTypeResolver? resolver,
}) => resolver?.call(destination) ?? defaultLiveMarkdownMediaType(destination);

/// Default media classification, ignoring a URL's query and fragment.
LiveMarkdownMediaType defaultLiveMarkdownMediaType(String destination) {
  final path = destination.split(RegExp(r'[?#]')).first.toLowerCase();
  final dot = path.lastIndexOf('.');
  final extension = dot < 0 ? '' : path.substring(dot);
  if (const {
    '.mp4',
    '.mov',
    '.m4v',
    '.webm',
    '.mkv',
    '.avi',
    '.mpeg',
    '.mpg',
    '.wmv',
    '.flv',
    '.ts',
    '.ogv',
  }.contains(extension)) {
    return LiveMarkdownMediaType.video;
  }
  if (const {
    '.mp3',
    '.wav',
    '.ogg',
    '.oga',
    '.m4a',
    '.m4b',
    '.aac',
    '.flac',
    '.opus',
  }.contains(extension)) {
    return LiveMarkdownMediaType.audio;
  }
  return LiveMarkdownMediaType.image;
}

LiveMarkdownMediaType? liveMarkdownMediaTypeForMime(String mimeType) {
  final mime = mimeType.split(';').first.trim().toLowerCase();
  if (mime.startsWith('image/')) return LiveMarkdownMediaType.image;
  if (mime.startsWith('video/')) return LiveMarkdownMediaType.video;
  if (mime.startsWith('audio/')) return LiveMarkdownMediaType.audio;
  return null;
}
