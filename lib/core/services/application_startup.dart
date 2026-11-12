import 'package:shared_preferences/shared_preferences.dart';

import 'app_preferences.dart';
import 'connection_manager.dart';

/// Compose the existing application owners from one device storage instance.
/// Flutter binding initialization precedes this call; WingApp owns their lifetime.
Future<({ConnectionManager connectionManager, AppPreferences appPreferences})>
createApplicationDependencies() async {
  final preferences = await SharedPreferences.getInstance();
  final connectionManager = await ConnectionManager.create(preferences);
  return (
    connectionManager: connectionManager,
    appPreferences: AppPreferences(preferences),
  );
}
