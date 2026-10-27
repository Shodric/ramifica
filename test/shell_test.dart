import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/app.dart';
import 'package:ramifica/app/navigation.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/app/shell_bloc.dart';
import 'package:ramifica/app/shell_event.dart';
import 'package:ramifica/app/shell_state.dart';
import 'package:ramifica/app/shell_view.dart';
import 'package:ramifica/features/explore/explore_view.dart';
import 'package:ramifica/features/feed/feed_view.dart';
import 'package:ramifica/features/graph/graph_view.dart';
import 'package:ramifica/features/profile/profile_view.dart';

void main() {
  test('tabs keep the open story', () async {
    final bloc = ShellBloc();
    addTearDown(bloc.close);

    bloc.add(const StoryOpenRequested('  story_temple  '));
    await bloc.stream.first;
    expect(bloc.state.tab, ShellTab.feed);
    expect(bloc.state.storyId, 'story_temple');

    bloc.add(const TabSelected(.explore));
    await bloc.stream.first;
    expect(bloc.state.tab, ShellTab.explore);
    expect(bloc.state.storyId, 'story_temple');

    bloc.add(const TabSelected(.graph, storyId: ' story_1 '));
    await bloc.stream.first;
    expect(bloc.state.tab, ShellTab.graph);
    expect(bloc.state.storyId, 'story_1');

    bloc.add(const StoryOpenRequested('   '));
    await Future<void>.delayed(Duration.zero);
    expect(bloc.state.tab, ShellTab.graph);
    expect(bloc.state.storyId, 'story_1');
  });

  testWidgets('switching tabs keeps Feed mounted and writes the path', (
    tester,
  ) async {
    await tester.pumpWidget(const RamificaApp(initialRoute: '/explore'));

    final before = tester.element(find.byType(FeedView, skipOffstage: false));
    await tester.tap(find.widgetWithText(NavigationDestination, 'Profile'));
    await tester.pump();

    final after = tester.element(find.byType(FeedView, skipOffstage: false));
    expect(identical(before, after), isTrue);
    expect(find.byType(ProfileView), findsOneWidget);
    expect(_path(tester), '/profile');
  });

  testWidgets('the browser path wins when the app opens at /', (tester) async {
    tester.platformDispatcher.defaultRouteNameTestValue = '/explore';
    addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);

    await tester.pumpWidget(const RamificaApp());

    expect(find.byType(ExploreView), findsOneWidget);
    expect(_path(tester), '/explore');
  });

  testWidgets('Map without a story stays on the current path', (tester) async {
    await tester.pumpWidget(const RamificaApp(initialRoute: '/explore'));

    await tester.tap(find.widgetWithText(NavigationDestination, 'Map'));
    await tester.pump();

    expect(find.byType(GraphView), findsOneWidget);
    expect(_path(tester), '/explore');
  });
}

String _path(WidgetTester tester) {
  return pathOf(
    AppNavigation.read(tester.element(find.byType(ShellView))).location,
  );
}
