import 'package:flutter/material.dart';
import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:dramabox_free/core/di/injection_container.dart' as di;
import 'package:dramabox_free/presentation/blocs/home_bloc.dart';
import 'package:dramabox_free/presentation/blocs/player_bloc.dart';
import 'package:dramabox_free/presentation/blocs/history_bloc.dart';
import 'package:dramabox_free/presentation/cubits/navigation_cubit.dart';
import 'package:dramabox_free/core/services/shorebird_service.dart';
import 'package:dramabox_free/core/services/video_proxy_service.dart';
import 'package:dramabox_free/presentation/pages/home_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  HttpOverrides.global = MyHttpOverrides();

  await Hive.initFlutter();
  await di.init();
  await di.sl<ShorebirdService>().init();
  await di.sl<VideoProxyService>().init();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<HomeBloc>(
          create: (context) => di.sl<HomeBloc>()..add(PreloadAllEvent()),
        ),
        BlocProvider<PlayerBloc>(create: (context) => di.sl<PlayerBloc>()),
        BlocProvider<HistoryBloc>(
          create: (context) => di.sl<HistoryBloc>()..add(LoadHistoryEvent()),
        ),
        BlocProvider<NavigationCubit>(
          create: (context) => di.sl<NavigationCubit>(),
        ),
      ],
      child: MaterialApp(
        title: 'DramaBox',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          primarySwatch: Colors.blue,
          scaffoldBackgroundColor: Colors.black,
        ),
        home: const HomePage(),
      ),
    );
  }
}

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;

    client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
      final host = proxyHost ?? uri.host;
      final port = proxyPort ?? uri.port;

      try {
        return await Socket.startConnect(host, port);
      } catch (e) {
        // If DNS fails (e.g. corporate VPN DNS conflict), fall back to Cloudflare edge IPs for Sansekai API
        if (host.contains('sansekai.my.id')) {
          const fallbackIps = ['172.67.173.251', '104.21.96.65'];
          for (final ip in fallbackIps) {
            try {
              return await Socket.startConnect(InternetAddress(ip), port);
            } catch (_) {}
          }
        }
        rethrow;
      }
    };

    return client;
  }
}
