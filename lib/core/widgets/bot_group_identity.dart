import 'package:flutter/material.dart';
import '../models/bots.dart';
import 'bot_group_picture.dart';

/// Saved room artwork takes precedence; otherwise frame the actual members.
class BotGroupIdentity extends StatelessWidget {
  const BotGroupIdentity({
    super.key,
    required this.group,
    required this.bots,
    required this.size,
  });
  final BotGroup group;
  final Iterable<BotRecord> bots;
  final double size;
  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label:
        '${group.members.length} bots: ${group.members.map((m) => m.name).join(', ')}',
    child: BotGroupPicture(
      color: group.iconColor,
      image: group.picture,
      size: size,
      avatars: [
        for (final member in group.members)
          bots
              .where(
                (bot) =>
                    bot.scope.connectionIdentity ==
                        group.scope.connectionIdentity &&
                    bot.profile.name == member.profile,
              )
              .firstOrNull,
      ],
    ),
  );
}
