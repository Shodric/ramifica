import 'package:flutter/widgets.dart';
import 'package:ramifica/app/routes.dart';

class AppRouteController extends ChangeNotifier {
  AppRouteController(this.location);

  AppLocation location;

  void go(String path) {
    final next = parseLocation(path);
    if (pathOf(next) == pathOf(location)) return;
    location = next;
    notifyListeners();
  }
}

class AppNavigation extends InheritedNotifier<AppRouteController> {
  const AppNavigation({
    required AppRouteController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static AppRouteController read(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<AppNavigation>();
    final scope = element?.widget;
    if (scope is! AppNavigation || scope.notifier == null) {
      throw FlutterError('AppNavigation is missing');
    }
    return scope.notifier!;
  }
}
