# Third-party licences

KhataPro's own code is MIT. Review this list before shipping a closed binary —
the encryption layer in particular carries notice obligations.

| Component | Licence | Obligation when you ship a closed APK/IPA |
|---|---|---|
| **SQLCipher** (via `package:sqlite3` hook `source: sqlcipher`) | BSD-style (Zetetic LLC) | include the copyright notice + licence text in the app's legal screen or an in-app "Open source licences" page. Free for commercial use; the community build is what we ship |
| SQLite itself | Public domain | none |
| Dart / Flutter SDK, `drift`, `flutter_riverpod`, `go_router`, `freezed`, `sqlite3.dart` | BSD-3 / MIT | include notices (Bundle-of-notices screen is enough) |
| `cryptography_plus`, `pointycastle`, `argon2`, `crypto` | MIT / Apache-2.0 / BSD | include notices |
| `googleapis`, `google_sign_in` (Google API terms) | BSD-3 + Google API ToS | Drive usage must display the app's own privacy policy and, for `drive.file`, request only that scope |
| `flutter_webrtc` | MIT | notices |
| `fl_chart` | MIT | notices |
| `pdf`, `printing` | Apache-2.0 / MIT | notices |
| **Inter** (SIL OFL 1.1) | OFL | may be embedded in a closed app; keep the licence file, do not sell the font alone |
| **Noto Nastaliq Urdu / Noto Naskh Arabic** (SIL OFL 1.1) | OFL | same |

Practical step for Deliverable 6: generate a single `lib/features/settings/presentation/licences_page.dart`
from `flutter pub deps` + the two SQLCipher/OFL notices, linked from Settings →
About. Play and the App Store both expect it to be reachable in-app.
