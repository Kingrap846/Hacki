import 'package:flutter/foundation.dart';
import 'package:hacki/config/locator.dart';
import 'package:hacki/models/models.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

/// [OfflineRepository] is for storing [Story] and [Comment] for
/// offline reading.
///
/// [Hive] is used as its database and is being stored in the temporary
/// directory assigned by host system which you can retrieve
/// by calling [getTemporaryDirectory].
class OfflineRepository {
  OfflineRepository({
    Future<Box<List<int>>>? storyIdBox,
    Future<Box<Map<dynamic, dynamic>>>? storyBox,
    Future<LazyBox<String>>? webPageBox,
    Future<LazyBox<Map<dynamic, dynamic>>>? commentBox,
    Logger? logger,
  })  : _storyIdBox = storyIdBox ?? Hive.openBox<List<int>>(_storyIdBoxName),
        _storyBox =
            storyBox ?? Hive.openBox<Map<dynamic, dynamic>>(_storyBoxName),
        _webPageBox = webPageBox ?? Hive.openLazyBox<String>(_webPageBoxName),
        _commentBox = commentBox ??
            Hive.openLazyBox<Map<dynamic, dynamic>>(_commentBoxName),
        _logger = logger ?? locator.get<Logger>();

  static const String _storyIdBoxName = 'storyIdBox';
  static const String _storyBoxName = 'storyBox';
  static const String _commentBoxName = 'commentBox';
  static const String _webPageBoxName = 'webPageBox';
  final Future<Box<List<int>>> _storyIdBox;
  final Future<Box<Map<dynamic, dynamic>>> _storyBox;
  final Future<LazyBox<Map<dynamic, dynamic>>> _commentBox;
  final Future<LazyBox<String>> _webPageBox;
  final Logger _logger;

  Future<bool> get hasCachedStories =>
      _storyBox.then((Box<Map<dynamic, dynamic>> box) => box.isNotEmpty);

  Future<void> cacheStoryIds({
    required StoryType type,
    required List<int> ids,
  }) async {
    late final Box<List<int>> box;

    try {
      box = await _storyIdBox;
    } catch (_) {
      _logger.e(_);
      await Hive.deleteBoxFromDisk(_storyIdBoxName);
      box = await _storyIdBox;
    }

    return box.put(type.name, ids);
  }

  Future<void> cacheStory({required Story story}) async {
    late final Box<Map<dynamic, dynamic>> box;

    try {
      box = await _storyBox;
    } catch (_) {
      _logger.e(_);
      await Hive.deleteBoxFromDisk(_storyBoxName);
      box = await _storyBox;
    }

    return box.put(story.id.toString(), story.toJson());
  }

  Future<void> cacheUrl({required String url}) async {
    late final LazyBox<String> box;

    try {
      box = await _webPageBox;
    } catch (_) {
      _logger.e(_);
      await Hive.deleteBoxFromDisk(_webPageBoxName);
      box = await _webPageBox;
    }

    final String html = await compute(_downloadWebPage, url);
    return box.put(url, html);
  }

  Future<String?> getHtml({required String url}) async {
    try {
      final LazyBox<String> box = await _webPageBox;
      return box.get(url);
    } catch (_) {
      _logger.e(_);
      await Hive.deleteBoxFromDisk(_webPageBoxName);
      return null;
    }
  }

  Future<bool> hasCachedWebPage({required String url}) async {
    try {
      final LazyBox<String> box = await _webPageBox;
      return box.containsKey(url);
    } catch (_) {
      _logger.e(_);
      await Hive.deleteBoxFromDisk(_webPageBoxName);
      return false;
    }
  }

  Future<List<int>> getCachedStoryIds({required StoryType type}) async {
    try {
      final Box<List<int>> box = await _storyIdBox;
      final List<int>? ids = box.get(type.name);
      return ids ?? <int>[];
    } catch (_) {
      _logger.e(_);
      await Hive.deleteBoxFromDisk(_storyIdBoxName);
      return <int>[];
    }
  }

  Stream<Story> getCachedStoriesStream({required List<int> ids}) async* {
    late final Box<Map<dynamic, dynamic>> box;

    try {
      box = await _storyBox;
    } catch (_) {
      _logger.e(_);
      await Hive.deleteBoxFromDisk(_storyBoxName);
      return;
    }

    for (final int id in ids) {
      final Map<dynamic, dynamic>? json = box.get(id.toString());

      if (json == null) {
        continue;
      }

      final Story story = Story.fromJson(json.cast<String, dynamic>());
      yield story;
    }

    return;
  }

  Future<Story?> getCachedStory({required int id}) async {
    late final Box<Map<dynamic, dynamic>> box;

    try {
      box = await _storyBox;
    } catch (_) {
      _logger.e(_);
      await Hive.deleteBoxFromDisk(_storyBoxName);
      return null;
    }

    final Map<dynamic, dynamic>? json = box.get(id.toString());
    if (json == null) {
      return null;
    }
    final Story story = Story.fromJson(json.cast<String, dynamic>());
    return story;
  }

  Future<void> cacheComment({required Comment comment}) async {
    late final LazyBox<Map<dynamic, dynamic>> box;

    try {
      box = await _commentBox;
    } catch (_) {
      _logger.e(_);
      await Hive.deleteBoxFromDisk(_commentBoxName);
      box = await _commentBox;
    }

    return box.put(comment.id.toString(), comment.toJson());
  }

  Future<Comment?> getCachedComment({required int id}) async {
    try {
      final LazyBox<Map<dynamic, dynamic>> box = await _commentBox;
      final Map<dynamic, dynamic>? json = await box.get(id.toString());
      if (json == null) {
        return null;
      }
      final Map<String, dynamic> typedJson = json.cast<String, dynamic>();
      typedJson['fromCache'] = true;
      final Comment comment = Comment.fromJson(typedJson);
      return comment;
    } catch (_) {
      _logger.e(_);
      await Hive.deleteBoxFromDisk(_commentBoxName);
      return null;
    }
  }

  Stream<Comment> getCachedCommentsStream({
    required List<int> ids,
    int level = 0,
  }) async* {
    final LazyBox<Map<dynamic, dynamic>> box = await _commentBox;

    for (final int id in ids) {
      final Map<dynamic, dynamic>? json = await box.get(id.toString());

      if (json != null) {
        final Map<String, dynamic> typedJson = json.cast<String, dynamic>();
        typedJson['fromCache'] = true;
        final Comment comment = Comment.fromJson(typedJson, level: level);

        yield comment;
        yield* getCachedCommentsStream(ids: comment.kids, level: level + 1);
      }
    }
  }

  Future<int> deleteAllStoryIds() async {
    try {
      final Box<List<int>> box = await _storyIdBox;
      return box.clear();
    } catch (_) {
      _logger.e(_);
      await Hive.deleteBoxFromDisk(_storyIdBoxName);
      return 0;
    }
  }

  Future<int> deleteAllStories() async {
    try {
      final Box<Map<dynamic, dynamic>> box = await _storyBox;
      return box.clear();
    } catch (_) {
      _logger.e(_);
      await Hive.deleteBoxFromDisk(_storyBoxName);
      return 0;
    }
  }

  Future<int> deleteAllComments() async {
    try {
      final LazyBox<Map<dynamic, dynamic>> box = await _commentBox;
      return box.clear();
    } catch (_) {
      _logger.e(_);
      await Hive.deleteBoxFromDisk(_commentBoxName);
      return 0;
    }
  }

  Future<int> deleteAllWebPages() async {
    try {
      final LazyBox<String> box = await _webPageBox;
      return box.clear();
    } catch (_) {
      _logger.e(_);
      await Hive.deleteBoxFromDisk(_webPageBoxName);
      return 0;
    }
  }

  Future<int> deleteAll() async {
    return deleteAllStoryIds()
        .whenComplete(deleteAllStories)
        .whenComplete(deleteAllComments)
        .whenComplete(deleteAllWebPages);
  }

  static Future<String> _downloadWebPage(String link) async {
    try {
      final Client client = Client();
      final Uri url = Uri.parse(link);
      final Response response = await client.get(url);
      final String body = response.body;
      client.close();
      return body;
    } catch (_) {
      return '''Web page not available.''';
    }
  }
}
