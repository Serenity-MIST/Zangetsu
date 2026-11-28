import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/profiles/profile_lock_store.dart';
import '../../core/profiles/profile_pin_store.dart';
import '../../core/profiles/synced_profile_lock_store.dart';
import '../../core/profiles/viewer_profile.dart';
import 'profile_lock_gate.dart' as cloud_lock;
import 'profile_pin_dialog.dart' show pinDialogPhoto, showProfilePinPrompt;
import '../../l10n/l10n.dart';

/// The one check every "open this profile" path goes through. It asks for at
/// most ONE PIN.
///
/// The profile lock is upstream's synced account lock ([ProfileLockStore]) on
/// every platform, so locking a profile on the PC also locks it on the phone
/// and TV. It verifies offline with the last PIN this device accepted online.
///
/// Windows only: a profile can still carry a PIN set by an older PC-only
/// build ([ProfilePinStore]). That old PIN is asked instead, then moved into
/// the synced lock (see [unlockWithLegacyPcPin]).
Future<bool> ensureProfileAccess(
  BuildContext context,
  ViewerProfile profile,
) async {
  if (await hasLegacyPcPin(profile.id)) {
    if (!context.mounted) return false;
    return unlockWithLegacyPcPin(context, profile);
  }
  if (!context.mounted) return false;
  return cloud_lock.ensureProfileUnlocked(context, profile);
}

/// Windows relock (acct-11): whether [profileId] has any PIN to ask for, the
/// old PC-only one or the synced lock. Uses the saved status first so it
/// works offline; only asks the lock store when nothing is saved. Any error
/// reads as "no PIN" so a relock never traps the user behind an unanswerable
/// prompt.
Future<bool> profileHasPin(
  String profileId,
  ProfileLockStore? locks,
) async {
  if (await hasLegacyPcPin(profileId)) return true;
  if (locks == null) return false;
  try {
    if (locks is SyncedProfileLockStore) {
      final cached = await locks.cachedLocked(profileId);
      if (cached != null) return cached;
    }
    return await locks.isLocked(profileId);
  } catch (_) {
    return false;
  }
}

/// Opens the PIN setup for [profile] from anywhere (Windows picker menu,
/// acct-7): an old PC-only PIN is moved into the synced lock first, like the
/// profile editor does, so the one shared lock is what gets managed.
/// Returns the locked state afterwards, or null when nothing changed.
Future<bool?> manageProfileLock(
  BuildContext context,
  ViewerProfile profile, {
  ProfileLockStore? locks,
}) async {
  final store =
      locks ??
      (sl.isRegistered<ProfileLockStore>() ? sl<ProfileLockStore>() : null);
  if (store == null) return null;
  if (await hasLegacyPcPin(profile.id)) {
    if (!context.mounted || !await unlockWithLegacyPcPin(context, profile)) {
      return null;
    }
    if (await hasLegacyPcPin(profile.id)) {
      // Still offline or signed out: the old PIN stays until it can move.
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.profileLockNeedsInternet,
            ),
          ),
        );
      }
      return null;
    }
  }
  if (!context.mounted) return null;
  return cloud_lock.manageProfilePin(
    context,
    profileId: profile.id,
    profileName: profile.name,
    locks: store,
  );
}

/// Windows: true while [profileId] still has a PIN from the old PC-only lock.
/// The store is registered on Windows only, so this is false elsewhere.
Future<bool> hasLegacyPcPin(String profileId) async =>
    sl.isRegistered<ProfilePinStore>() &&
    await sl<ProfilePinStore>().hasPin(profileId);

/// Opens a profile that still has an old PC-only PIN, asking one PIN only.
///
/// - Synced lock already set (e.g. from the phone): that lock is the one
///   lock, so the synced PIN is asked and the old PC PIN is dropped once it
///   opens the profile.
/// - Otherwise the old PC PIN is asked with its own verifier. When correct and
///   online, the same PIN is enrolled into the synced lock and the old one is
///   deleted; offline (or signed out) the old PIN stays and keeps protecting
///   the profile until it can be moved.
Future<bool> unlockWithLegacyPcPin(
  BuildContext context,
  ViewerProfile profile, {
  ProfilePinStore? pins,
  ProfileLockStore? locks,
}) async {
  final legacy = pins ?? sl<ProfilePinStore>();
  final synced =
      locks ??
      (sl.isRegistered<ProfileLockStore>() ? sl<ProfileLockStore>() : null);
  bool? syncedLocked;
  try {
    syncedLocked = synced == null ? false : await synced.isLocked(profile.id);
  } catch (_) {
    // Offline with no saved status, or signed out: unknown. The old PIN
    // still applies, so ask it below rather than dropping protection.
    syncedLocked = null;
  }
  if (!context.mounted) return false;
  if (syncedLocked == true) {
    final ok = await cloud_lock.ensureProfileUnlocked(
      context,
      profile,
      locks: synced,
    );
    if (ok) await legacy.forget(profile.id);
    return ok;
  }
  String? accepted;
  final ok = await showProfilePinPrompt(
    context,
    profile: profile,
    store: legacy,
    photoUrl: pinDialogPhoto(profile),
    onAccepted: (pin) => accepted = pin,
  );
  final pin = accepted;
  if (!ok || pin == null) return false;
  if (synced != null && await moveLegacyPcPin(profile.id, pin, legacy, synced)) {
    if (context.mounted) {
      await cloud_lock.showProfileLockRecoveryCode(context, synced, profile.id);
    }
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            "${profile.name}'s PIN now locks this profile on all your devices.",
          ),
        ),
      );
    }
  }
  return true;
}

/// Enrolls an already-verified old PC [pin] into the synced lock, then
/// deletes the old PIN. Returns false (old PIN kept) when the synced lock
/// cannot take it right now: offline, signed out, or refused by the server.
Future<bool> moveLegacyPcPin(
  String profileId,
  String pin,
  ProfilePinStore legacy,
  ProfileLockStore synced,
) async {
  try {
    if (!await synced.setPin(profileId, pin)) return false;
  } catch (_) {
    return false;
  }
  await legacy.forget(profileId);
  return true;
}
