import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:juno/app/shell.dart';
import 'package:juno/features/activity/activity_screen.dart';
import 'package:juno/features/home/home_screen.dart';
import 'package:juno/features/import/import_screen.dart';
import 'package:juno/features/insights/category_screen.dart';
import 'package:juno/features/insights/insights_screen.dart';
import 'package:juno/features/insights/review_screen.dart';
import 'package:juno/features/plan/goal_screen.dart';
import 'package:juno/features/plan/plan_screen.dart';
import 'package:juno/features/settings/accounts_screen.dart';
import 'package:juno/features/settings/ai_screen.dart';
import 'package:juno/features/settings/back_tap_screen.dart';
import 'package:juno/features/settings/backups_screen.dart';
import 'package:juno/features/settings/categories_screen.dart';
import 'package:juno/features/settings/currencies_screen.dart';
import 'package:juno/features/settings/settings_screen.dart';
import 'package:juno/features/settings/sync_screen.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

final router = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: '/home',
  // juno://add links are handled by DeepLinkHandler, not as routes; if the
  // OS hands one to the router anyway, land on Home.
  redirect: (context, state) => state.uri.scheme == 'juno' || state.uri.path == '/add' ? '/home' : null,
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => AppShell(shell: shell),
      branches: [
        StatefulShellBranch(
          routes: [GoRoute(path: '/home', builder: (_, _) => const HomeScreen())],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/activity', builder: (_, _) => const ActivityScreen())],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/insights',
              builder: (_, _) => const InsightsScreen(),
              routes: [
                GoRoute(
                  path: 'review',
                  parentNavigatorKey: rootNavigatorKey,
                  builder: (_, _) => const ReviewScreen(),
                ),
                GoRoute(
                  path: 'category/:id',
                  parentNavigatorKey: rootNavigatorKey,
                  builder: (_, s) => CategoryScreen(categoryId: s.pathParameters['id']!),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/plan',
              builder: (_, _) => const PlanScreen(),
              routes: [
                GoRoute(
                  path: 'goal/:id',
                  parentNavigatorKey: rootNavigatorKey,
                  builder: (_, s) => GoalScreen(goalId: s.pathParameters['id']!),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              builder: (_, _) => const SettingsScreen(),
              routes: [
                GoRoute(path: 'accounts', builder: (_, _) => const AccountsScreen()),
                GoRoute(path: 'categories', builder: (_, _) => const CategoriesScreen()),
                GoRoute(path: 'import', builder: (_, _) => const ImportScreen()),
                GoRoute(path: 'back-tap', builder: (_, _) => const BackTapScreen()),
                GoRoute(path: 'sync', builder: (_, _) => const SyncScreen()),
                GoRoute(path: 'currencies', builder: (_, _) => const CurrenciesScreen()),
                GoRoute(path: 'backups', builder: (_, _) => const BackupsScreen()),
                GoRoute(path: 'ai', builder: (_, _) => const AiScreen()),
              ],
            ),
          ],
        ),
      ],
    ),
  ],
);
