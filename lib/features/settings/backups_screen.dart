import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/db/backups.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/sync/sync_engine.dart';
import 'package:juno/core/toast.dart';
import 'package:juno/core/ui/ui.dart';

class BackupsScreen extends ConsumerStatefulWidget {
  const BackupsScreen({super.key});

  @override
  ConsumerState<BackupsScreen> createState() => _BackupsScreenState();
}

class _BackupsScreenState extends ConsumerState<BackupsScreen> {
  List<BackupFile>? _list;
  bool _busy = false;

  Backups get _backups => Backups(ref.read(databaseProvider));

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final l = await _backups.list();
      if (mounted) setState(() => _list = l);
    } on Object {
      if (mounted) setState(() => _list = const []);
    }
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } on Object catch (e) {
      showToast('Backup action failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  static String _when(DateTime d) {
    final t = TimeOfDay.fromDateTime(d);
    return '${d.day}/${d.month}/${d.year} · ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final list = _list;
    return JScreen(
      eyebrow: 'Settings · Backups',
      title: 'Nothing gets *lost*',
      subtitle:
          'Juno snapshots this device once a day and keeps two weeks. Restoring brings back anything missing — it never overwrites newer changes.',
      actions: [
        JIconButton(icon: Icons.arrow_back_rounded, tooltip: 'Back', onPressed: () => Navigator.of(context).maybePop()),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: JSpace.sm,
                runSpacing: JSpace.sm,
                children: [
                  JButton(
                    label: _busy ? 'Working…' : 'Back up now',
                    icon: Icons.backup_outlined,
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await _backups.snapshot();
                            showToast('Backup saved');
                          }),
                  ),
                  if (list != null && list.isNotEmpty)
                    JButton(
                      label: 'Export latest',
                      icon: Icons.ios_share_rounded,
                      kind: JButtonKind.secondary,
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              final f = list.first.file;
                              await FilePicker.saveFile(
                                fileName: f.uri.pathSegments.last,
                                bytes: Uint8List.fromList(await f.readAsBytes()),
                              );
                            }),
                    ),
                  JButton(
                    label: 'Restore from file…',
                    icon: Icons.settings_backup_restore_rounded,
                    kind: JButtonKind.ghost,
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            final files = await FilePicker.pickFiles(dialogTitle: 'Choose a Juno backup');
                            if (files.isEmpty) return;
                            final tmp = File(
                              '${Directory.systemTemp.path}/juno-import-${clock.now().microsecondsSinceEpoch}.sqlite',
                            );
                            await tmp.writeAsBytes(await files.first.readAsBytes());
                            final n = await _backups.restore(tmp);
                            await tmp.delete();
                            await ref.read(syncEngineProvider.notifier).syncNow();
                            showToast(n == 0 ? 'Nothing to restore — this device is up to date' : 'Restored $n items');
                          }),
                  ),
                ],
              ),
              const JSectionLabel('On this device'),
              if (list == null)
                const SizedBox(height: 60)
              else if (list.isEmpty)
                Text('No backups yet — the first one is made today.', style: JType.body.copyWith(color: c.inkMuted))
              else
                JGroup(
                  children: [
                    for (final b in list)
                      JSettingRow(
                        icon: Icons.inventory_2_outlined,
                        title: _when(b.at),
                        subtitle: '${(b.bytes / 1024).round()} KB',
                        trailing: JButton(
                          label: 'Restore',
                          kind: JButtonKind.ghost,
                          dense: true,
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  final n = await _backups.restore(b.file);
                                  await ref.read(syncEngineProvider.notifier).syncNow();
                                  showToast(
                                    n == 0 ? 'Nothing to restore — this device is up to date' : 'Restored $n items',
                                  );
                                }),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}
