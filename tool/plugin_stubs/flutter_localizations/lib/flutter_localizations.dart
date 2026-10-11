/// Analyzer stub for `package:flutter_localizations` (the Flutter SDK package).
///
/// The app declares this dependency for one reason: **Urdu**. `MaterialApp` needs delegates to
/// localise the strings the *framework* draws — the back button's tooltip, a date picker's
/// month names, the semantics labels a screen reader reads — and without them an `ur` locale
/// gets English framework strings inside an Urdu, right-to-left layout.
///
/// The real `GlobalMaterialLocalizations` carries the CLDR tables for ~80 languages; this stub
/// carries the four members the app touches. Nothing here runs.
library;

import 'package:flutter/material.dart';

class GlobalMaterialLocalizations extends LocalizationsDelegate<Object> {
  const GlobalMaterialLocalizations();
  static const LocalizationsDelegate<Object> delegate = GlobalMaterialLocalizations();
}

class GlobalWidgetsLocalizations extends LocalizationsDelegate<Object> {
  const GlobalWidgetsLocalizations();
  static const LocalizationsDelegate<Object> delegate = GlobalWidgetsLocalizations();
}

class GlobalCupertinoLocalizations extends LocalizationsDelegate<Object> {
  const GlobalCupertinoLocalizations();
  static const LocalizationsDelegate<Object> delegate = GlobalCupertinoLocalizations();
}
