import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;

import '../../ide/ide_hover.dart';
import '../../theme/app_theme.dart';
import '../../theme/material_file_icons.dart';
import '../../theme/workbench_theme.dart' show WorkbenchThemeScope, themeColors;
import '../../workspace/editor_launcher.dart';
import '../side_panel/file_link.dart';
import '../side_panel/file_link_menu.dart';
import '../composer/composer_embeds.dart' show FileImageChip;
import '../side_panel/file_open.dart';
import 'code_citation.dart';
import 'content_image.dart';
import 'hover_scrollbar.dart';
import 'inline_code.dart';
import 'markdown_cjk.dart';
import 'markdown_math.dart';
import 'markdown_tags.dart';
import 'mermaid_code_block.dart';

/// GitHub-flavored markdown as plain widgets (so a surrounding
/// `SelectionArea` selects and copies it): headings, paragraphs, lists
/// (and task lists), code blocks, quotes, tables, rules, and inline
/// strong, emphasis, strikethrough, code, links and TeX math.
class MarkdownView extends StatefulWidget {
  const MarkdownView(this.data, {super.key, this.style});

  final String data;

  /// [baseStyle] when null.
  final TextStyle? style;

  static TextStyle get baseStyle =>
      TextStyle(color: AppColors.text, fontSize: 13.5, height: 1.6);

  /// Inline code's, its background painted by [InlineCodeText].
  static TextStyle get codeStyle =>
      AppFonts.uiCodeStyle(12.5).copyWith(color: AppColors.inlineCode);

  /// The block syntaxes of its own, before GFM's: code citations and TeX.
  static const blockSyntaxes = <md.BlockSyntax>[
    CodeCitationFenceSyntax(),
    MathBlockSyntax(),
  ];
  static List<md.InlineSyntax> get inlineSyntaxes => [
    InlineMathSyntax(),
    CjkEmphasisSyntax(),
  ];

  /// A document parsing as it does; one keeps the link definitions it
  /// read (see the IDE's markdown preview). The chat's has [tags] too: a
  /// block between tags as a section that folds ([TagBlockSyntax]).
  static md.Document document({bool tags = false}) => md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    blockSyntaxes: [...blockSyntaxes, if (tags) const TagBlockSyntax()],
    inlineSyntaxes: inlineSyntaxes,
    encodeHtml: false,
  );

  static final _document = document(tags: true);

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  /// What it built last, and from what. The history rebuilds the messages
  /// it shows as a reply streams in, the pointer moves in…: parsed again,
  /// its file icons new widgets, each paragraph would be laid out anew.
  Widget? _built;
  Object? _builtFrom;

  /// The blocks already finished, as widgets built once: while a reply
  /// streams in, only the block being written changes. Parsing the whole
  /// of a long message on every frame and laying it out again is what a
  /// reply costs (tens of milliseconds at 30 000 characters); a finished
  /// block is kept as it was, and only the last one is made again.
  final List<Widget> _chunks = [];

  /// How much of [MarkdownView.data] [_chunks] was built from, and that
  /// text kept to know whether an edit still begins with it.
  int _chunkEnd = 0;
  String _chunkText = '';

  /// What the chunks were built with: another style or theme is another
  /// set of widgets.
  Object? _chunkFrom;

  /// The images the finished blocks showed, and all of them for a click
  /// on one to go through: the last block's are added as it is parsed,
  /// the finished blocks' are read from the shared list.
  final List<String> _settledImages = [];
  final List<String> _gallery = [];

  /// What files are known to exist. A file found changes icons already
  /// built, which are made again then.
  FileExistence? _existence;
  int _existenceVersion = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _built = null;
    _forgetChunks();
    final existence = FileOpenScope.maybeOf(context)?.existence;
    if (!identical(existence, _existence)) {
      _existence?.removeListener(_existenceFound);
      _existence = existence;
      _existence?.addListener(_existenceFound);
      _existenceVersion = 0;
    }
  }

  @override
  void dispose() {
    _existence?.removeListener(_existenceFound);
    super.dispose();
  }

  /// A file was found: the icons of what was built before it are not the
  /// ones to show.
  void _existenceFound() {
    _existenceVersion++;
    _forgetChunks();
    // What was built holds the old icons: made again, not handed back.
    _built = null;
    _builtFrom = null;
    if (mounted) setState(() {});
  }

  void _forgetChunks() {
    _chunks.clear();
    _settledImages.clear();
    _gallery.clear();
    _chunkEnd = 0;
    _chunkText = '';
    _chunkFrom = null;
  }

  @override
  Widget build(BuildContext context) {
    final from = (
      widget.data,
      widget.style,
      themeColors,
      WorkbenchThemeScope.restyles,
      _existenceVersion,
    );
    if (_built case final built? when from == _builtFrom) return built;
    _builtFrom = from;
    return _built = _build(context);
  }

  Widget _build(BuildContext context) {
    final MarkdownView(:data, :style) = widget;
    final textStyle = style ?? MarkdownView.baseStyle;
    // In a chat whose files open (see FileOpenScope): links to them, and
    // inline code naming one once it is known to be there.
    final files = FileOpenScope.maybeOf(context);
    // What the blocks were built as: the scope itself is made anew on
    // rebuilds of the chat, its project and its files' existence are not.
    final look = (
      style,
      themeColors,
      WorkbenchThemeScope.restyles,
      files?.root,
      files?.existence,
      _existenceVersion,
    );
    if (look != _chunkFrom) {
      _forgetChunks();
      _chunkFrom = look;
    }
    // An edit: what was kept is not how this text begins anymore.
    if (_chunkEnd > 0 &&
        (data.length < _chunkEnd || !data.startsWith(_chunkText))) {
      _forgetChunks();
    }

    final MarkdownOptions options;
    if (files == null) {
      options = const MarkdownOptions();
    } else {
      Widget? icon(FileLink? link) {
        final path = link == null ? null : files.resolve(link.path);
        if (path == null) return null;
        return _isFolder(link!.path, files.existence.known(path))
            ? FolderIcon(path, size: _fileIconSize)
            : FileIcon(path, size: _fileIconSize);
      }

      options = MarkdownOptions(
        link: (href) =>
            _linkRecognizer(href) ??
            files.linkRecognizer(href, context: context),
        code: (code) => files.codeRecognizer(code, context: context),
        linkIcon: (href) => icon(FileLink.parseHref(href)),
        codeIcon: (code) => icon(FileLink.parseText(code)),
        // An image as an attached one's tag.
        fileTag: (href, label) {
          final link = FileLink.parseHref(href);
          final path = link == null || link.range != null
              ? null
              : files.resolve(link.path);
          if (path == null || !files.showsImage(path)) return null;
          return FileImageChip.span(
            path: path,
            label: label.trim().isEmpty
                ? (files.paths ?? p.context).basename(path)
                : label.trim(),
            files: files,
            textStyle: textStyle,
          );
        },
        // An image file as it is; the others of the message a click away.
        image: (src, alt, title, {width, height}) {
          final path = markdownImagePath(src, files);
          if (path == null) return _imageLink(src, alt);
          return MarkdownImage(
            path: path,
            alt: alt,
            files: files,
            gallery: _gallery,
          );
        },
      );
    }

    // What is surely finished, kept; the block still being written, made
    // again. A block is finished when a blank line ends it: a fence, a
    // math block or a tag section still open is not.
    //
    // A reference link's definition is read by the document as a whole,
    // wherever it is written: a message with one is parsed whole.
    final linked = _linkDefinition.hasMatch(data);
    if (linked && _chunks.isNotEmpty) _forgetChunks();
    final cut = linked ? _chunkEnd : _settledCut(data, _chunkEnd);
    if (cut > _chunkEnd) {
      final nodes = MarkdownView._document.parse(
        data.substring(_chunkEnd, cut),
      );
      if (files != null) {
        _settledImages.addAll([
          for (final src in _imageSources(nodes))
            ?markdownImagePath(src, files),
        ]);
      }
      _chunks.add(
        MarkdownBlocks(
          nodes: nodes,
          style: textStyle,
          options: options,
          leadingGap: _leadingGap(nodes, options),
        ),
      );
      _chunkEnd = cut;
      _chunkText = data.substring(0, cut);
    }
    final tail = data.substring(_chunkEnd);
    final tailNodes = tail.isEmpty
        ? const <md.Node>[]
        : MarkdownView._document.parse(tail);
    if (files != null) {
      // The same list the blocks already built read, so a click on one of
      // theirs finds the last block's too.
      _gallery
        ..clear()
        ..addAll(_settledImages)
        ..addAll([
          for (final src in _imageSources(tailNodes))
            ?markdownImagePath(src, files),
        ]);
    }
    final tailBlocks = tailNodes.isEmpty
        ? null
        : MarkdownBlocks(
            nodes: tailNodes,
            style: textStyle,
            options: options,
            leadingGap: _leadingGap(tailNodes, options),
          );
    Widget blocks(BuildContext context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [..._chunks, ?tailBlocks],
    );
    if (files == null) return blocks(context);
    // Code is a link, and a link's icon a file's, once the file is found.
    if (!data.contains('`') && !data.contains('](')) return blocks(context);
    return ListenableBuilder(
      listenable: files.existence,
      builder: (context, _) => blocks(context),
    );
  }

  /// The gap before [nodes]' first block, or none when they are the
  /// message's first.
  double _leadingGap(List<md.Node> nodes, MarkdownOptions options) =>
      _chunks.isEmpty || nodes.isEmpty
      ? 0
      : MarkdownBlocks.gapBefore(nodes.first, options);
}

/// A reference link's definition: `[name]: address`, read by the whole
/// document and not by the block it stands beside.
final _linkDefinition = RegExp(r'^\s{0,3}\[[^\]]+\]:', multiLine: true);

/// Where [data] can be cut into what is finished and what is still being
/// written: the start of the block after a blank line — never inside a
/// fenced code block, a math block or a tag section still open, and never
/// before a line that goes on with a list, a quote, a table or an
/// indented block (which a blank line may separate, not end).
int _settledCut(String data, int from) {
  var cut = from;
  var fence = '';
  String? math;
  var tag = '';
  var tagDepth = 0;
  var tagFence = '';
  var offset = from;
  while (offset < data.length) {
    final newline = data.indexOf('\n', offset);
    final end = newline < 0 ? data.length : newline;
    final line = data.substring(offset, end);
    final next = newline < 0 ? data.length : newline + 1;
    final indent = line.length - line.trimLeft().length;
    final content = line.substring(indent);
    final marker = indent <= 3 ? _fenceMarker(content) : null;
    if (fence.isNotEmpty) {
      if (marker != null &&
          marker[0] == fence[0] &&
          marker.length >= fence.length &&
          content.substring(marker.length).trim().isEmpty) {
        fence = '';
      }
    } else if (math != null) {
      if (line.trimRight().endsWith(math)) math = null;
    } else if (tag.isNotEmpty) {
      // Code within it, whose lines are not tags.
      if (tagFence.isNotEmpty) {
        if (marker != null &&
            marker[0] == tagFence[0] &&
            marker.length >= tagFence.length) {
          tagFence = '';
        }
      } else if (marker != null) {
        tagFence = marker;
      } else if (TagBlockSyntax.closes(line, tag)) {
        if (--tagDepth == 0) tag = '';
      } else if (TagBlockSyntax.reopens(line, tag)) {
        tagDepth++;
      }
    } else {
      final opens = indent <= 3 ? MathBlockSyntax.opens(line) : null;
      final section = indent <= 3 ? TagBlockSyntax.opens(line) : null;
      if (marker != null) {
        fence = marker;
      } else if (opens != null) {
        math = opens;
      } else if (section != null) {
        tag = section;
        tagDepth = 1;
      } else if (line.trim().isEmpty && next < data.length) {
        final after = _nextBlockStart(data, next);
        if (after != null) cut = after;
      }
    }
    offset = next;
  }
  return cut;
}

/// The fence [content] opens or closes (``` or ~~~, three or more).
String? _fenceMarker(String content) =>
    RegExp(r'^(`{3,}|~{3,})').firstMatch(content)?[1];

/// Where the block beginning after a blank line at [from] starts; null
/// when there is none, or it goes on with what the blank line separates.
int? _nextBlockStart(String data, int from) {
  var offset = from;
  while (offset < data.length) {
    final newline = data.indexOf('\n', offset);
    final end = newline < 0 ? data.length : newline;
    final line = data.substring(offset, end);
    if (line.trim().isNotEmpty) return _continues(line) ? null : offset;
    offset = newline < 0 ? data.length : newline + 1;
  }
  return null;
}

/// Whether [line] goes on with a list, a quote, a table or an indented
/// block: no blank line ends those.
bool _continues(String line) {
  final indent = line.length - line.trimLeft().length;
  if (indent >= 4) return true;
  final content = line.substring(indent);
  if (content.startsWith('>') || content.startsWith('|')) return true;
  if (content.startsWith('- ') ||
      content.startsWith('* ') ||
      content.startsWith('+ ')) {
    return true;
  }
  return RegExp(r'^\d{1,9}[.)](\s|$)').hasMatch(content);
}

/// The `src` of each image in [nodes], in the order they come.
List<String> _imageSources(List<md.Node> nodes) {
  final sources = <String>[];
  void visit(md.Node node) {
    if (node is! md.Element) return;
    if (node.tag == 'img') sources.add(_unescape(node.attributes['src'] ?? ''));
    node.children?.forEach(visit);
  }

  nodes.forEach(visit);
  return sources;
}

/// An image the chat does not show (one on the web: its address could
/// tell a server what the agent read): its alt text, a link to it.
Widget _imageLink(String src, String alt) {
  final label = '[${alt.isEmpty ? 'image' : alt}]';
  final recognizer = _linkRecognizer(src);
  if (recognizer is! TapGestureRecognizer) {
    return Text(label, style: TextStyle(color: AppColors.textMuted));
  }
  return MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: recognizer.onTap,
      child: IdeHover(
        message: src,
        child: Text(label, style: TextStyle(color: AppColors.accent)),
      ),
    ),
  );
}

/// How [MarkdownBlocks] draws and what its links, images and task boxes
/// do: as the chat's by default.
@immutable
class MarkdownOptions {
  const MarkdownOptions({
    this.headingSizes = const [19, 17, 15, 13.5, 13.5, 13.5],
    this.headingRules = false,
    this.gap = 8,
    this.headingGap = 12,
    this.link,
    this.code,
    this.linkIcon,
    this.codeIcon,
    this.fileTag,
    this.image,
    this.onToggleTask,
  });

  /// `h1` to `h6`'s font sizes.
  final List<double> headingSizes;

  /// Whether `h1` and `h2` have a line under them, as GitHub's.
  final bool headingRules;

  /// The space between blocks, and before and after a heading.
  final double gap;
  final double headingGap;

  /// What a tap on a link to `href` does; web and mail links open in the
  /// browser when null, others nothing.
  final GestureRecognizer? Function(String? href)? link;

  /// What a tap on inline code does (it names a file, say); nothing when
  /// null, or it gives none.
  final GestureRecognizer? Function(String code)? code;

  /// What is drawn before a link to `href` (or inline code, see [code]):
  /// the icon of the file or folder it opens, say; nothing when null.
  final Widget? Function(String? href)? linkIcon;
  final Widget? Function(String code)? codeIcon;

  /// What a link to `href` labeled [label] shows in its place, as a tag:
  /// an image file's, say; the link when null, or it gives none.
  final InlineSpan? Function(String? href, String label)? fileTag;

  /// An image (`![alt](src "title")`, or HTML's with its [width] and
  /// [height] in pixels); its alt text in brackets when null.
  final Widget Function(
    String src,
    String alt,
    String? title, {
    double? width,
    double? height,
  })?
  image;

  /// Called with a task list box's number (see [numberTasks]) when it is
  /// clicked; the boxes are only drawn when null.
  final ValueChanged<int>? onToggleTask;
}

/// Numbers the task list boxes of [nodes], in the order their lines come,
/// for [MarkdownOptions.onToggleTask].
void numberTasks(List<md.Node> nodes) {
  var count = 0;
  void visit(md.Node node) {
    if (node is! md.Element) return;
    if (node.tag == 'input') node.attributes[_taskAttribute] = '${count++}';
    node.children?.forEach(visit);
  }

  nodes.forEach(visit);
}

const _taskAttribute = 'data-task';

/// Parsed markdown ([MarkdownView.document]) as widgets.
class MarkdownBlocks extends StatelessWidget {
  const MarkdownBlocks({
    super.key,
    required this.nodes,
    required this.style,
    this.options = const MarkdownOptions(),
    this.leadingGap = 0,
  });

  final List<md.Node> nodes;
  final TextStyle style;
  final MarkdownOptions options;

  /// The gap before its first block, where it is not the message's first:
  /// a message is built a finished block at a time (see `MarkdownView`),
  /// and the gap belongs to the block after it.
  final double leadingGap;

  /// The gap before [node] as one of the blocks.
  static double gapBefore(md.Node node, MarkdownOptions options) =>
      switch (node) {
        md.Element(tag: 'h1' || 'h2' || 'h3') => options.headingGap,
        _ => options.gap,
      };

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final node in nodes) {
      final block = _block(node, style, options);
      if (block == null) continue;
      if (children.isNotEmpty) {
        children.add(SizedBox(height: gapBefore(node, options)));
      } else if (leadingGap > 0) {
        children.add(SizedBox(height: leadingGap));
      }
      children.add(block);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

Widget? _block(md.Node node, TextStyle style, MarkdownOptions options) {
  if (node is md.Text) {
    if (node.text.trim().isEmpty || isHtmlComment(node.text)) return null;
    return Text.rich(TextSpan(style: style, text: node.text));
  }
  if (node is! md.Element) return null;
  switch (node.tag) {
    case 'math':
      return MathView(node.textContent, display: true);
    case 'p':
      return InlineCodeText(
        _inlines(node.children ?? const [], style, options),
      );
    case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
      final level = int.parse(node.tag.substring(1));
      final heading = Padding(
        padding: const EdgeInsets.only(top: 2),
        child: InlineCodeText(
          _inlines(
            node.children ?? const [],
            style.copyWith(
              color: AppColors.textPrimary,
              fontSize: options.headingSizes[level - 1],
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
            options,
          ),
        ),
      );
      if (!options.headingRules || level > 2) return heading;
      return Container(
        padding: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.partBorder)),
        ),
        child: heading,
      );
    case 'ul' || 'ol':
      return _List(node: node, style: style, options: options);
    case 'pre':
      final code = node.children?.firstOrNull;
      final text = code is md.Element ? code.textContent : node.textContent;
      final language = code is md.Element
          ? code.attributes['class']?.replaceFirst('language-', '')
          : null;
      final body = text.endsWith('\n')
          ? text.substring(0, text.length - 1)
          : text;
      if (CodeCitation.parse(language) case final citation?) {
        return CodeCitationCard(citation: citation, code: body);
      }
      // `python title="a.py"`: the language is the first word.
      final name = language?.trim().split(RegExp(r'\s')).first;
      if (name?.toLowerCase() == 'mermaid') {
        return MermaidCodeBlock(code: body);
      }
      return MarkdownCodeBlock(
        code: body,
        language: name == null || name.isEmpty ? null : name,
      );
    case 'blockquote':
      final children = node.children ?? const <md.Node>[];
      return MarkdownQuoteBlock(
        // Its paragraphs' text, as they read.
        text: children.map((child) => child.textContent).join('\n\n'),
        child: MarkdownBlocks(
          nodes: children,
          style: style.copyWith(color: AppColors.textMuted),
          options: options,
        ),
      );
    case 'hr':
      // As upstream's chat: the separator's color, faint.
      final separator = themeColors['textSeparator.foreground'];
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Divider(
          height: 1,
          color: separator.withValues(alpha: separator.a * 0.33),
        ),
      );
    case 'table':
      return _Table(node: node, style: style, options: options);
    case TagBlockSyntax.tag:
      return TagSection(node: node, style: style, options: options);
    default:
      return InlineCodeText(_inlines([node], style, options));
  }
}

/// A list, numbered or not, whose items may hold blocks and nested lists.
class _List extends StatelessWidget {
  const _List({required this.node, required this.style, required this.options});

  final md.Element node;
  final TextStyle style;
  final MarkdownOptions options;

  @override
  Widget build(BuildContext context) {
    final ordered = node.tag == 'ol';
    final start = int.tryParse(node.attributes['start'] ?? '') ?? 1;
    final items = [
      for (final child in node.children ?? const <md.Node>[])
        if (child is md.Element && child.tag == 'li') child,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, item) in items.indexed)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: ordered ? 24 : 18,
                  child: _marker(item, ordered ? '${start + i}.' : '•'),
                ),
                Expanded(child: _itemBody(item)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _marker(md.Element item, String text) {
    final checkbox = item.children?.firstOrNull;
    if (checkbox is md.Element && checkbox.tag == 'input') {
      final checked = checkbox.attributes['checked'] != null;
      final box = Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Icon(
          checked ? Icons.check_box_rounded : Icons.check_box_outline_blank,
          size: 14,
          color: checked ? AppColors.added : AppColors.textMuted,
        ),
      );
      final toggle = options.onToggleTask;
      final task = int.tryParse(checkbox.attributes[_taskAttribute] ?? '');
      if (toggle == null || task == null) return box;
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => toggle(task),
          child: box,
        ),
      );
    }
    return Text(text, style: style.copyWith(color: AppColors.textMuted));
  }

  /// An item's text and blocks: a tight item's text is inline children, a
  /// loose one's is paragraphs.
  Widget _itemBody(md.Element item) {
    final children = [
      for (final child in item.children ?? const <md.Node>[])
        if (!(child is md.Element && child.tag == 'input')) child,
    ];
    final inline = <md.Node>[];
    final blocks = <Widget>[];
    void flush() {
      if (inline.isEmpty) return;
      blocks.add(InlineCodeText(_inlines([...inline], style, options)));
      inline.clear();
    }

    for (final child in children) {
      final isBlock =
          child is md.Element &&
          const {
            'p',
            'ul',
            'ol',
            'pre',
            'blockquote',
            'table',
            'h1',
            'h2',
            'h3',
            'h4',
            'hr',
          }.contains(child.tag);
      if (!isBlock) {
        inline.add(child);
        continue;
      }
      flush();
      final block = _block(child, style, options);
      if (block != null) blocks.add(block);
    }
    flush();
    if (blocks.length == 1) return blocks.single;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, block) in blocks.indexed) ...[
          if (i > 0) const SizedBox(height: 4),
          block,
        ],
      ],
    );
  }
}

/// A table in a card as the steps' are, as wide as its columns up to the
/// width there is; wider, it scrolls sideways, with a bar to show it while
/// the pointer is over it or it scrolls.
class _Table extends StatefulWidget {
  const _Table({
    required this.node,
    required this.style,
    required this.options,
  });

  final md.Element node;
  final TextStyle style;
  final MarkdownOptions options;

  @override
  State<_Table> createState() => _TableState();
}

class _TableState extends State<_Table> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final rows = <(bool, List<md.Element>)>[];
    for (final section in widget.node.children ?? const <md.Node>[]) {
      if (section is! md.Element) continue;
      for (final row in section.children ?? const <md.Node>[]) {
        if (row is! md.Element || row.tag != 'tr') continue;
        rows.add((
          section.tag == 'thead',
          [
            for (final cell in row.children ?? const <md.Node>[])
              if (cell is md.Element) cell,
          ],
        ));
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    final columns = rows
        .map((row) => row.$2.length)
        .reduce((a, b) => a > b ? a : b);
    final line = BorderSide(color: themeColors['chat.requestBorder']);
    final table = Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      // The card draws the edge.
      border: TableBorder.symmetric(inside: line),
      children: [
        for (final (header, cells) in rows)
          TableRow(
            decoration: header
                ? BoxDecoration(color: AppColors.surfaceRaised)
                : null,
            children: [
              for (var i = 0; i < columns; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: i < cells.length
                      ? InlineCodeText(
                          _inlines(
                            cells[i].children ?? const [],
                            header
                                ? style.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary,
                                  )
                                : style,
                            widget.options,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
            ],
          ),
      ],
    );
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Container(
        // The edge over the cells, the header's color clipped to the corners.
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.fromBorderSide(line),
        ),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: HoverScrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            child: table,
          ),
        ),
      ),
    );
  }
}

TextSpan _inlines(
  List<md.Node> nodes,
  TextStyle style,
  MarkdownOptions options,
) => TextSpan(
  style: style,
  children: [for (final node in nodes) _inline(node, options)],
);

InlineSpan _inline(md.Node node, MarkdownOptions options) {
  if (node is md.Text) {
    // A comment is the writer's note, not shown (as HTML has it); the
    // parser joins it to the text after it.
    final text = node.text.contains('<!--')
        ? node.text.replaceAll(_htmlComment, '')
        : node.text;
    return TextSpan(text: _unescape(text));
  }
  if (node is! md.Element) return const TextSpan();
  final children = node.children ?? const <md.Node>[];
  List<InlineSpan> inner() => [
    for (final child in children) _inline(child, options),
  ];
  if (node.tag == 'a') {
    final href = node.attributes['href'];
    if (options.fileTag?.call(href, _unescape(node.textContent))
        case final tag?) {
      return tag;
    }
  }
  return switch (node.tag) {
    'strong' || 'b' => TextSpan(
      style: TextStyle(
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      children: inner(),
    ),
    'em' || 'i' => TextSpan(
      style: const TextStyle(fontStyle: FontStyle.italic),
      children: inner(),
    ),
    'del' => TextSpan(
      style: const TextStyle(decoration: TextDecoration.lineThrough),
      children: inner(),
    ),
    'code' => switch (options.code?.call(_unescape(node.textContent))) {
      // A file's: in the link's color, its icon first in the background.
      final recognizer? => InlineCodeSpan(
        style: MarkdownView.codeStyle.copyWith(color: AppColors.accent),
        children: [
          if (options.codeIcon?.call(_unescape(node.textContent))
              case final icon?)
            _linkIcon(
              icon,
              recognizer,
              const EdgeInsets.only(left: 4, right: 3),
            )
          else
            const TextSpan(text: ' '),
          TextSpan(
            text: '${_unescape(node.textContent)} ',
            recognizer: recognizer,
            mouseCursor: SystemMouseCursors.click,
          ),
        ],
      ),
      null => InlineCodeSpan(
        text: ' ${_unescape(node.textContent)} ',
        style: MarkdownView.codeStyle,
      ),
    },
    'a' => switch ((options.link ?? _linkRecognizer)(node.attributes['href'])) {
      final recognizer? => TextSpan(
        style: TextStyle(color: AppColors.accent),
        children: [
          if (options.linkIcon?.call(node.attributes['href']) case final icon?)
            _linkIcon(icon, recognizer, const EdgeInsets.only(right: 3)),
          for (final span in inner()) _linked(span, recognizer),
        ],
      ),
      null => TextSpan(
        style: TextStyle(color: AppColors.accent),
        children: inner(),
      ),
    },
    'math' => WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: MathView(
        node.textContent,
        display: node.attributes['display'] == 'block',
      ),
    ),
    'br' => const TextSpan(text: '\n'),
    'img' => switch (options.image) {
      final image? => WidgetSpan(
        child: image(
          _unescape(node.attributes['src'] ?? ''),
          _unescape(node.attributes['alt'] ?? ''),
          node.attributes['title'],
          width: double.tryParse(node.attributes['width'] ?? ''),
          height: double.tryParse(node.attributes['height'] ?? ''),
        ),
      ),
      null => TextSpan(text: '[${node.attributes['alt'] ?? 'image'}]'),
    },
    _ => TextSpan(children: inner()),
  };
}

/// Opens [href] in the default browser (or mail app). Only web and mail
/// links: the text is the agent's, and `open` would as well run a local
/// file or app.
GestureRecognizer? _linkRecognizer(String? href) {
  final uri = href == null ? null : Uri.tryParse(href.trim());
  if (uri == null || !const {'http', 'https', 'mailto'}.contains(uri.scheme)) {
    return null;
  }
  return TapGestureRecognizer()..onTap = () => openExternal(uri.toString());
}

/// Whether [text] is HTML comments alone (`<!-- note -->`), which do not
/// show.
bool isHtmlComment(String text) => _htmlComments.hasMatch(text);

final _htmlComments = RegExp(r'^\s*(?:<!--[\s\S]*?-->\s*)+$');
final _htmlComment = RegExp(r'<!--[\s\S]*?-->');

const _fileIconSize = 14.0;

/// Whether a link to [written] (as the agent wrote it), [known] to be a
/// file or not (see [FileExistence.known]), goes to a folder: one written
/// with a slash after it, or a name without an extension that is not a
/// file found (`lib/ide`, not `LICENSE`).
bool _isFolder(String written, bool? known) {
  if (written.endsWith('/') || written.endsWith(r'\')) return true;
  if (known == true) return false;
  final name = written.split(RegExp(r'[/\\]')).last;
  // A leading dot is not an extension's (`.github`).
  return name.lastIndexOf('.') <= 0;
}

/// [icon] before a link: a tap on it goes where the link does.
WidgetSpan _linkIcon(
  Widget icon,
  GestureRecognizer recognizer,
  EdgeInsets padding,
) {
  icon = Padding(padding: padding, child: icon);
  if (recognizer is FileLinkRecognizer) {
    icon = FileLinkMenuRegion(menu: recognizer.menu, child: icon);
  }
  if (recognizer is TapGestureRecognizer) {
    icon = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: recognizer.onTap,
        child: icon,
      ),
    );
  }
  return WidgetSpan(alignment: PlaceholderAlignment.middle, child: icon);
}

/// [span] with every piece of its text tappable: a tap lands on the
/// innermost span, which does not inherit its parent's recognizer.
InlineSpan _linked(InlineSpan span, GestureRecognizer recognizer) =>
    switch (span) {
      // Code in a link keeps its background, and goes where the link does.
      InlineCodeSpan(:final text, :final style) => InlineCodeSpan(
        text: text,
        style: style,
        recognizer: recognizer,
        mouseCursor: SystemMouseCursors.click,
      ),
      // An image in a link (`[![alt](src)](href)`).
      WidgetSpan(:final child, :final alignment)
          when recognizer is TapGestureRecognizer =>
        WidgetSpan(
          alignment: alignment,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(onTap: recognizer.onTap, child: child),
          ),
        ),
      TextSpan(:final text, :final style, :final children) => TextSpan(
        text: text,
        style: style,
        recognizer: recognizer,
        mouseCursor: SystemMouseCursors.click,
        children: [
          for (final child in children ?? const <InlineSpan>[])
            _linked(child, recognizer),
        ],
      ),
      _ => span,
    };

String _unescape(String text) => text
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");
