import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The logos of models and their makers, in one color: Iconify's (Simple
/// Icons, theSVG, Remix Icon), kept in `assets/model_icons/`, drawn in the
/// color of the text around them.
abstract final class BrandLogos {
  /// Each by its file's name, as it is listed (and searched) in the icon
  /// picker: its maker's name.
  static const names = {
    'claude': 'Claude',
    'claudecode': 'Claude Code',
    'anthropic': 'Anthropic',
    'openai': 'OpenAI',
    'gemini': 'Gemini',
    'google': 'Google',
    'deepseek': 'DeepSeek',
    'qwen': 'Qwen',
    'zhipu': 'Zhipu GLM',
    'kimi': 'Kimi',
    'moonshot': 'Moonshot AI',
    'minimax': 'MiniMax',
    'doubao': 'Doubao',
    'bytedance': 'ByteDance',
    'volcengine': 'Volcengine',
    'hunyuan': 'Hunyuan',
    'wenxin': 'ERNIE',
    'stepfun': 'StepFun',
    'baichuan': 'Baichuan',
    'yi': 'Yi',
    'xai': 'xAI Grok',
    'mistral': 'Mistral AI',
    'meta': 'Meta Llama',
    'microsoft': 'Microsoft',
    'nvidia': 'NVIDIA',
    'perplexity': 'Perplexity',
    'githubcopilot': 'GitHub Copilot',
    'openrouter': 'OpenRouter',
    'siliconflow': 'SiliconFlow',
    'together': 'Together AI',
    'fireworks': 'Fireworks AI',
    'huggingface': 'Hugging Face',
    'ollama': 'Ollama',
    'lmstudio': 'LM Studio',
    'azure': 'Azure AI',
    'bedrock': 'Amazon Bedrock',
    'vertexai': 'Vertex AI',
    'cloudflare': 'Cloudflare',
    'vercel': 'Vercel',
  };

  static String asset(String name) => 'assets/model_icons/$name.svg';
}

/// Logo [name] of [BrandLogos] in a square of [size], in [color].
class BrandLogo extends StatelessWidget {
  const BrandLogo(this.name, {super.key, required this.size, this.color});

  final String name;
  final double size;

  /// The text's when null.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? DefaultTextStyle.of(context).style.color;
    return SvgPicture.asset(
      BrandLogos.asset(name),
      width: size,
      height: size,
      colorFilter: color == null
          ? null
          : ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}

/// MoonCode's own mark, without the app icon's tile
/// (`assets/branding/logo.svg`): [size] wide, in [color] (the icons' around
/// it when null), as a codicon is drawn.
class BaoCodeLogo extends StatelessWidget {
  const BaoCodeLogo({super.key, this.size = 16, this.color});

  /// The mark on its own, the tile's black taken out: white where it is
  /// drawn on something dark, black where it is not ([color] chooses).
  static const white = 'assets/branding/logo-white.png';
  static const black = 'assets/branding/logo-black.png';

  /// Kept for callers that name the old path: the white one.
  static const asset = white;

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? IconTheme.of(context).color;
    // A dark ink on a light surface reads the mark as black; a light one,
    // as white. Both are the same shape, so the file follows the colour.
    final dark = color == null || color.computeLuminance() < 0.5;
    return SizedBox.square(
      dimension: size,
      child: Center(
        child: Image.asset(
          dark ? black : white,
          width: size,
          height: size,
          filterQuality: FilterQuality.medium,
          // Tinted to the theme's colour where one is given, so that the
          // mark sits in a row of icons as one of them.
          color: color,
          colorBlendMode: color == null ? null : BlendMode.srcIn,
        ),
      ),
    );
  }
}
