import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/desktop_settings_surface.dart';
import '../../core/ui/settings_widgets.dart';
import '../../l10n/l10n.dart';
import '../../core/ui/team_section.dart';
import 'desktop_settings_workspace.dart' show DesktopSettingsColumn;

/// The people behind Zangetsu: the curated core team (with roles) followed by
/// "Community Contributors" — everyone else who's contributed on GitHub, pulled
/// live. The community list is empty until someone new contributes.
class ContributorsScreen extends StatefulWidget {
  const ContributorsScreen({super.key});

  @override
  State<ContributorsScreen> createState() => _ContributorsScreenState();
}

class _ContributorsScreenState extends State<ContributorsScreen> {
  late final Future<List<TeamMember>> _community = fetchCommunity();

  @override
  Widget build(BuildContext context) {
    if (DesktopSettingsScope.contains(context)) return _desktopPage(context);
    return Scaffold(
      backgroundColor: settingsPageBackground(context),
      appBar: settingsAppBar(context.l10n.contributors),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          SettingsSectionLabel(context.l10n.team, first: true, muted: true),
          for (final m in kCoreTeam)
            SettingsCard(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              children: [_ContributorTile(member: m)],
            ),
          SettingsSectionLabel(context.l10n.communityContributors, muted: true),
          // Hand-listed first — people with no commits to their name, so the
          // GitHub fetch below can't turn them up.
          for (final m in kFixedCommunity)
            SettingsCard(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              children: [_ContributorTile(member: m)],
            ),
          FutureBuilder<List<TeamMember>>(
            future: _community,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 22),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              final list = snap.data ?? const <TeamMember>[];
              // "No contributors yet" would contradict the hand-listed rows
              // sitting right above it, so it only stands in for an empty
              // section as a whole.
              if (list.isEmpty) {
                return kFixedCommunity.isEmpty
                    ? const _CommunityEmpty()
                    : const SizedBox.shrink();
              }
              return Column(
                children: [
                  for (final m in list)
                    SettingsCard(
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      children: [_ContributorTile(member: m)],
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// Windows settings: laid out like the Reader page. Each section is one
  /// card of rows (avatar, name, role, link) in the shared settings column,
  /// under a section title, instead of a separate card per person.
  Widget _desktopPage(BuildContext context) {
    return Scaffold(
      backgroundColor: settingsPageBackground(context),
      appBar: settingsAppBar(context.l10n.contributors),
      body: ListView(
        padding: DesktopSettingsScope.listPadding(context, top: 4, bottom: 28),
        children: [
          SettingsSectionLabel(context.l10n.team, first: true),
          SettingsCard(
            children: [for (final m in kCoreTeam) _ContributorTile(member: m)],
          ),
          SettingsSectionLabel(context.l10n.communityContributors),
          FutureBuilder<List<TeamMember>>(
            future: _community,
            builder: (context, snap) {
              final loading = snap.connectionState != ConnectionState.done;
              // Hand-listed first: people with no commits to their name, so
              // the GitHub fetch can't turn them up.
              final people = [...kFixedCommunity, if (!loading) ...?snap.data];
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (people.isNotEmpty)
                    SettingsCard(
                      children: [
                        for (final m in people) _ContributorTile(member: m),
                      ],
                    ),
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 22),
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else if (people.isEmpty)
                    const _CommunityEmpty(),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// One contributor row: avatar, name, role, and an open-link affordance.
class _ContributorTile extends StatelessWidget {
  const _ContributorTile({required this.member});

  final TeamMember member;

  Future<void> _open() async {
    final uri = Uri.parse(member.link);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Windows settings: the shared settings row, so name, role and the link
    // mark stand in the same columns as the Reader page's rows.
    if (DesktopSettingsScope.contains(context)) {
      return SettingsTile(
        icon: Icons.person_rounded,
        leading: TeamAvatar(url: member.avatar, name: member.name, size: 36),
        title: member.name,
        subtitle: member.role,
        trailing: const Icon(
          Icons.arrow_outward_rounded,
          size: 18,
          color: AppColors.textTertiary,
        ),
        onTap: _open,
      );
    }
    return InkWell(
      onTap: _open,
      splashColor: AppColors.accent.withValues(alpha: 0.08),
      highlightColor: AppColors.accent.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
        child: Row(
          children: [
            TeamAvatar(url: member.avatar, name: member.name, size: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    member.name,
                    style: AppText.headline.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 15.5,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    member.role,
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.arrow_outward_rounded,
              size: 16,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown while no one outside the core team has contributed yet.
class _CommunityEmpty extends StatelessWidget {
  const _CommunityEmpty();

  @override
  Widget build(BuildContext context) {
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          context.l10n.noCommunityContributorsYet,
          style: AppText.body.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 4),
        Text(
          context.l10n.openPullRequestOnGitHub,
          style: AppText.caption.copyWith(
            color: AppColors.textTertiary,
            height: 1.4,
          ),
        ),
      ],
    );
    // Windows settings: in the cards' column, where the section titles start.
    if (DesktopSettingsScope.contains(context)) {
      return DesktopSettingsColumn(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
          child: text,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
      child: text,
    );
  }
}
