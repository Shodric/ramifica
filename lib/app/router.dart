import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ramifica/app/navigation.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/app/shell_view.dart';

class AppRouteInformationParser extends RouteInformationParser<AppLocation> {
  const AppRouteInformationParser();

  @override
  Future<AppLocation> parseRouteInformation(
    RouteInformation routeInformation,
  ) {
    return SynchronousFuture(parseLocation(routeInformation.uri.path));
  }

  @override
  RouteInformation restoreRouteInformation(AppLocation configuration) {
    return RouteInformation(uri: Uri.parse(pathOf(configuration)));
  }
}

class RamificaRouterDelegate extends RouterDelegate<AppLocation>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<AppLocation> {
  RamificaRouterDelegate(this.controller) {
    controller.addListener(notifyListeners);
  }

  final AppRouteController controller;
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  GlobalKey<NavigatorState> get navigatorKey => _navigatorKey;

  @override
  AppLocation get currentConfiguration => controller.location;

  @override
  Future<void> setNewRoutePath(AppLocation configuration) async {
    final next = pathOf(configuration);
    if (next == pathOf(controller.location)) return;
    controller.location = configuration;
    controller.notifyListeners();
  }

  @override
  void dispose() {
    controller.removeListener(notifyListeners);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: navigatorKey,
      pages: [
        MaterialPage<void>(
          key: const ValueKey('app'),
          child: ShellGate(location: controller.location),
        ),
      ],
      onDidRemovePage: (_) => notifyListeners(),
    );
  }
}
