import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/auth/auth_controller.dart';
import 'core/l10n/gen/app_localizations.dart';
import 'features/auth/login_screen.dart';
import 'features/coach/coach_screen.dart';
import 'features/home/home_screen.dart';
import 'features/home/shell_scaffold.dart';
import 'features/moments/moments_screen.dart';
import 'features/nutrition/log_meal_screen.dart';
import 'features/nutrition/meal_detail_screen.dart';
import 'features/nutrition/nutrition_screen.dart';
import 'features/progress/progress_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/sleep/sleep_screen.dart';
import 'features/training/manual_workout_screen.dart';
import 'features/training/recorder_screen.dart';
import 'features/training/training_screen.dart';
import 'features/training/workout_crop_screen.dart';
import 'features/training/run_detail_screen.dart';
import 'features/training/workout_edit_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(authControllerProvider);

  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      if (!auth.booted) return null;
      final onLogin = state.matchedLocation == '/login';
      if (!auth.isSignedIn) return onLogin ? null : '/login';
      if (onLogin) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),

      // Recording and detail screens are full-screen: the tab bar would only
      // get in the way mid-workout.
      GoRoute(path: '/record', builder: (_, __) => const RecorderScreen()),
      GoRoute(
        path: '/workouts/manual',
        builder: (_, __) => const ManualWorkoutScreen(),
      ),
      GoRoute(
        path: '/workouts/:id/edit',
        builder: (_, state) =>
            WorkoutEditScreen(sessionId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/workouts/:id/crop',
        builder: (_, state) =>
            WorkoutCropScreen(sessionId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/workouts/:id',
        builder: (_, state) =>
            WorkoutRoute(sessionId: state.pathParameters['id']!),
      ),
      GoRoute(path: '/meals/new', builder: (_, __) => const LogMealScreen()),
      GoRoute(
        path: '/meals/:id',
        builder: (_, state) =>
            MealDetailScreen(mealId: state.pathParameters['id']!),
      ),

      ShellRoute(
        builder: (_, __, child) => ShellScaffold(child: child),
        routes: [
          GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
          GoRoute(
            path: '/nutrition',
            builder: (_, __) => const NutritionScreen(),
          ),
          GoRoute(
            path: '/training',
            builder: (_, __) => const TrainingScreen(),
          ),
          GoRoute(path: '/sleep', builder: (_, __) => const SleepScreen()),
          GoRoute(
            path: '/progress',
            builder: (_, __) => const ProgressScreen(),
          ),
          GoRoute(path: '/coach', builder: (_, __) => const CoachScreen()),
          GoRoute(path: '/moments', builder: (_, __) => const MomentsScreen()),
          GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Text(AppL10n.of(context).routeMissing('${state.uri}')),
      ),
    ),
  );
});
