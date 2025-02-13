import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hacki/config/constants.dart';
import 'package:hacki/models/models.dart';
import 'package:hacki/repositories/repositories.dart';
import 'package:hacki/utils/utils.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_android/path_provider_android.dart';
import 'package:path_provider_foundation/path_provider_foundation.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';
import 'package:shared_preferences_foundation/shared_preferences_foundation.dart';
import 'package:workmanager/workmanager.dart';

void fetcherCallbackDispatcher() {
  Workmanager()
      .executeTask((String task, Map<String, dynamic>? inputData) async {
    if (Platform.isAndroid) {
      PathProviderAndroid.registerWith();
      SharedPreferencesAndroid.registerWith();
    } else if (Platform.isIOS) {
      PathProviderFoundation.registerWith();
      SharedPreferencesFoundation.registerWith();
    }

    await Fetcher.fetchReplies();

    return Future<bool>.value(true);
  });
}

abstract class Fetcher {
  static const int _subscriptionUpperLimit = 15;

  static Future<void> fetchReplies() async {
    final Logger logger = Logger();
    final PreferenceRepository preferenceRepository =
        PreferenceRepository(logger: logger);
    final AuthRepository authRepository = AuthRepository(
      preferenceRepository: preferenceRepository,
      logger: logger,
    );
    final SembastRepository sembastRepository = SembastRepository();
    final HackerNewsRepository hackerNewsRepository = HackerNewsRepository(
      sembastRepository: sembastRepository,
      logger: logger,
    );
    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();

    final String? username = await authRepository.username;
    final List<int> unreadIds = await preferenceRepository.unreadCommentsIds;

    if (username == null || username.isEmpty) return;

    Comment? newReply;

    await hackerNewsRepository
        .fetchSubmitted(userId: username)
        .then((List<int>? submittedItems) async {
      if (submittedItems != null) {
        final List<int> subscribedItems = submittedItems.sublist(
          0,
          min(_subscriptionUpperLimit, submittedItems.length),
        );

        for (final int id in subscribedItems) {
          await hackerNewsRepository
              .fetchRawItem(id: id)
              .then((Item? item) async {
            final List<int> kids = item?.kids ?? <int>[];
            final List<int> previousKids =
                (await sembastRepository.kids(of: id)) ?? <int>[];

            await sembastRepository.updateKidsOf(id: id, kids: kids);

            final Set<int> diff =
                <int>{...kids}.difference(<int>{...previousKids});

            if (diff.isNotEmpty) {
              for (final int newCommentId in diff) {
                if (unreadIds.contains(newCommentId)) continue;

                await hackerNewsRepository
                    .fetchRawComment(id: newCommentId)
                    .then((Comment? comment) async {
                  final bool hasPushedBefore =
                      await preferenceRepository.hasPushed(newReply!.id);

                  if (comment != null && !comment.dead && !comment.deleted) {
                    await sembastRepository.saveComment(comment);
                    await sembastRepository.updateIdsOfCommentsRepliedToMe(
                      comment.id,
                    );

                    if (!hasPushedBefore) {
                      newReply = comment;
                    }
                  }
                });

                if (newReply != null) break;
              }
            }
          });

          if (newReply != null) break;
        }
      }
    });

    // Push notification for new unread reply that has not been
    // pushed before.
    if (newReply != null) {
      final Story? story =
          await hackerNewsRepository.fetchRawParentStory(id: newReply!.id);
      final String text = HtmlUtil.parseHtml(newReply!.text);

      if (story != null) {
        final Map<String, int> payloadJson = <String, int>{
          'commentId': newReply!.id,
          'storyId': story.id,
        };
        final String payload = jsonEncode(payloadJson);

        await preferenceRepository.updateHasPushed(newReply!.id);

        await flutterLocalNotificationsPlugin.show(
          newReply?.id ?? 0,
          'You have a new reply! ${Constants.happyFace}',
          '${newReply?.by}: $text',
          const NotificationDetails(
            iOS: DarwinNotificationDetails(
              presentBadge: false,
              threadIdentifier: 'hacki',
            ),
          ),
          payload: payload,
        );
      }
    }
  }
}
