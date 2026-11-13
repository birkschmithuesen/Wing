import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/bots.dart';
import '../models/profile_colors.dart';
import '../theme/profile_colors.dart';
import 'bot_avatar.dart';

/// One passive room identity shared by creation, the roster and conversation.
class BotGroupPicture extends StatelessWidget {
  const BotGroupPicture({
    super.key,
    this.avatars = const [],
    this.color,
    this.image,
    this.size = 40,
  });
  final List<BotRecord?> avatars;
  final ProfileColorChoice? color;
  final Uint8List? image;
  final double size;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final frameColor = color?.slot == null
        ? colors.primaryContainer
        : desktopProfileSwatches[color!.slot!];
    final radius = BorderRadius.circular(size * .15);
    final collage = Padding(
      padding: EdgeInsets.all((size * .045).clamp(1.5, 3)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * .11),
        child: ColoredBox(
          color: colors.surfaceContainerHigh,
          child: _collage(context),
        ),
      ),
    );
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: radius,
        child: SizedBox.square(
          dimension: size,
          child: ColoredBox(
            color: frameColor,
            child: image == null
                ? collage
                : Image.memory(
                    image!,
                    fit: BoxFit.cover,
                    cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                        .ceil(),
                    errorBuilder: (_, _, _) => collage,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _collage(BuildContext context) {
    if (avatars.isEmpty) {
      return Center(
        child: Icon(
          Icons.group_outlined,
          size: size * .55,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    final members = avatars.take(6).toList();
    final points = _memberPositions(members.length);
    final minX = points.map((point) => point.dx).reduce(math.min);
    final minY = points.map((point) => point.dy).reduce(math.min);
    final width = points.map((point) => point.dx).reduce(math.max) - minX + 1;
    final height = points.map((point) => point.dy).reduce(math.max) - minY + 1;
    final layers = points.indexed.toList()
      ..sort((a, b) => a.$2.dy.compareTo(b.$2.dy));
    return LayoutBuilder(
      builder: (_, constraints) {
        final avatarSize =
            .9 *
            math.min(
              constraints.maxWidth / width,
              constraints.maxHeight / height,
            );
        final origin = Offset(
          (constraints.maxWidth - width * avatarSize) / 2 - minX * avatarSize,
          (constraints.maxHeight - height * avatarSize) / 2 - minY * avatarSize,
        );
        return Stack(
          children: layers.map((entry) {
            final (index, point) = entry;
            final bot = members[index];
            return Positioned(
              left: origin.dx + point.dx * avatarSize,
              top: origin.dy + point.dy * avatarSize,
              child: bot == null
                  ? SizedBox.square(dimension: avatarSize)
                  : BorrowedBotAvatar(
                      bot: bot,
                      name: bot.title,
                      size: avatarSize,
                    ),
            );
          }).toList(),
        );
      },
    );
  }

  List<Offset> _memberPositions(int count) {
    if (count == 1) return const [Offset.zero];
    if (count == 2) return const [Offset(-.38, 0), Offset(.38, 0)];
    final radius = .78 / (2 * math.sin(math.pi / count));
    final start = count == 4 ? -math.pi * .75 : -math.pi * .5;
    return [
      for (var index = 0; index < count; index++)
        Offset(
          math.cos(start + index * 2 * math.pi / count) * radius,
          math.sin(start + index * 2 * math.pi / count) * radius,
        ),
    ];
  }
}
