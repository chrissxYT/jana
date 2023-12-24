import 'dart:convert';

import 'package:mutex/mutex.dart';
import 'package:nyxx/nyxx.dart';
import 'package:nyxx_extensions/nyxx_extensions.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

final log = Logger('jana');

final internalId = Snowflake(826983242493591592);
final newsId = Snowflake(551908144641605642);
final yt = YoutubeExplode();

Stream<Video> getVideos() => yt.channels.getUploads('UCZs3FO5nPvK9VveqJLIvv_w');
Map videoToJson(Video v) => {
      'author': v.author,
      'channelId': v.channelId.value,
      'description': v.description,
      'duration': v.duration?.inSeconds,
      'hasWatchPage': v.hasWatchPage,
      'id': v.id.value,
      'isLive': v.isLive,
      'publishDate': v.publishDate?.toIso8601String(),
      'title': v.title,
      'uploadDate': v.uploadDate?.toIso8601String(),
      'uploadDateRaw': v.uploadDateRaw,
      'url': v.url,
    }..removeWhere((key, value) => value == null);

extension SendJson on TextChannel {
  Future sendJson(String json, [String fileName = "message.json"]) {
    if (json.length < 1984) {
      return sendMessage(MessageBuilder(content: '```json\n$json\n```'));
    } else {
      return sendMessage(MessageBuilder(attachments: [
        AttachmentBuilder(fileName: fileName, data: utf8.encode(json))
      ]));
    }
  }
}

void main(List<String> argv) async {
  final bot = await Nyxx.connectGateway(argv.first,
      GatewayIntents.allUnprivileged | GatewayIntents.messageContent,
      options: GatewayClientOptions(plugins: [Logging(), CliIntegration()]));

  final internal = await bot.channels.get(internalId) as TextChannel;

  final logMutex = Mutex();
  Message? lastLog;
  var lastLogMsg = '';
  var lastLogCount = 1;
  Logger.root.onRecord.listen((rec) => logMutex.protect(() async {
        final ping = rec.level >= Level.WARNING ? ' @pixelcmtd' : '';
        var msg = '[${rec.level.name}] [${rec.loggerName}] ${rec.message}$ping';
        if (rec.error != null) msg += '\nError: ${rec.error}';
        if (rec.stackTrace != null) {
          msg += '\nStack trace:\n```${rec.stackTrace}```';
        }
        if (lastLogMsg == msg) {
          lastLog
              ?.edit(MessageUpdateBuilder(content: '$msg x${++lastLogCount}'));
        } else {
          lastLog = await internal.sendMessage(MessageBuilder(content: msg));
          lastLogCount = 1;
          lastLogMsg = msg;
        }
      }));

  bot.onMessageCreate.listen((event) async {
    final msg = event.message;
    final channel = await msg.channel.get() as TextChannel;
    if (msg.author is Webhook || (msg.author as User).isBot) return;
    log.info(
        'Msg from ${msg.author.username}: ${msg.content} (${await msg.url})');
    if (msg.content == '!ping') {
      await channel.sendMessage(MessageBuilder(content: 'Pong!'));
    } else if (msg.content == '!vids') {
      await channel.sendJson(
          json.encode(await getVideos().map(videoToJson).toList()),
          'vids.json');
    } else if (msg.content.startsWith('!vid')) {
      final ids = msg.content.split(' ')..removeAt(0);
      for (final id in ids) {
        try {
          await yt.videos.get(id).then(
              (v) => channel.sendJson(json.encode(videoToJson(v)), '$id.json'));
        } catch (e, st) {
          log.warning('!vid error', e, st);
          await channel.sendMessage(MessageBuilder(content: e.toString()));
        }
      }
    }
  });

  final sent = await getVideos().map((v) => v.id.value).toList();
  Future.delayed(Duration(minutes: 5), () => checkYoutube(bot, sent));
}

void checkYoutube(NyxxGateway bot, List<String> sent) async {
  log.info('Searching for new videos/streams...');
  try {
    final vids = getVideos()
        .map((v) => v.id)
        .where((v) => !sent.contains(v.value))
        .asyncMap(yt.videos.get);
    // TODO: log what happens here
    // TODO: consider putting the message before the video it belongs to
    final messages = <String>[];
    final reactions = <String>[];
    final links = <String>[];
    final ids = <String>[];
    await for (final vid in vids) {
      ids.add(vid.id.value);
      if ((vid.publishDate ?? vid.uploadDate ?? DateTime.now())
      // TODO: proper replacement for this
          .isBefore(DateTime(2023, 12, 13))) {
        log.warning('an old video came through: ${vid.url}');
        bot.channels.get(internalId).then((c) => c as TextChannel).then((chan) {
          chan.sendJson(json.encode(videoToJson(vid)), 'oldvid.json');
        });
        continue;
      }
      messages.addAll(vid.description
          .replaceAll('\r', '')
          .split('\n')
          .where((s) => s.startsWith('janamsg: '))
          .map((s) => s.replaceFirst('janamsg: ', '')));
      reactions.addAll(vid.description
          .replaceAll('\r', '')
          .split('\n')
          .where((s) => s.startsWith('janareact: '))
          .map((s) => s.replaceFirst('janareact: ', '')));
      links.add('https://youtu.be/${vid.id.value}');
    }
    if (links.isNotEmpty) {
      final message = messages.reduce((a, b) => '$a\n$b');
      final link = links.reduce((p, e) => '$p $e');
      final msg = await bot.channels
          .get(newsId)
          .then((c) => c as TextChannel)
          .then((chan) => chan.sendMessage(
              MessageBuilder(content: '@everyone $message\n$link')));
      await Future.wait(reactions
          .map(bot.getTextEmoji)
          .map(ReactionBuilder.fromEmoji)
          .map(msg.react));
    }
    sent.addAll(ids);
  } catch (e, st) {
    log.severe('yt update error', e, st);
  }
  Future.delayed(Duration(minutes: 5), () => checkYoutube(bot, sent));
}
