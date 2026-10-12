/// KhataPro — the entry point with global error boundaries.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'apps/bootstrap.dart';
import 'apps/khata_app.dart';

void main() {
  // 1. Ensure WidgetsFlutterBinding is the absolute first line.
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Custom ErrorWidget to prevent the release-mode Grey Screen of Death on widget build failures.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return _buildErrorApp(
      title: 'UI Render Error',
      details: '${details.exceptionAsString()}\n\n${details.stack}',
    );
  };

  // 3. Catch Flutter framework errors.
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    _showErrorFallback(details.exception, details.stack);
  };

  // 4. Wrap the entire boot sequence and runApp() in runZonedGuarded.
  runZonedGuarded<void>(
    () {
      runApp(KhataBootstrap(builder: (context, boot) => KhataApp(boot: boot)));
    },
    (error, stack) {
      _showErrorFallback(error, stack);
    },
  );
}

bool _hasShownFallback = false;

void _showErrorFallback(Object error, StackTrace? stack) {
  if (_hasShownFallback) return;
  _hasShownFallback = true;
  runApp(
    _buildErrorApp(
      title: 'Initialization Error',
      details: '$error\n\n${stack ?? ''}',
    ),
  );
}

Widget _buildErrorApp({required String title, required String details}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.redAccent, size: 28),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF121212),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      details,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
