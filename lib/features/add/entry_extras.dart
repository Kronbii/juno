import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/attachments/attachment_store.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/fx.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/ui/ui.dart';

/// Tags on an entry: selected tags as removable chips, a field to type new
/// ones (comma or enter to add), and your most-used tags one tap away.
class TagEditor extends ConsumerWidget {
  const TagEditor({required this.tags, required this.input, required this.onChanged, super.key});

  final List<String> tags;
  final TextEditingController input;
  final ValueChanged<List<String>> onChanged;

  void _commit() {
    final add = EntryTags.fromInput(input.text);
    if (add.isEmpty) return;
    onChanged({...tags, ...add}.toList());
    input.clear();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final known = (ref.watch(tagsProvider).value ?? const <(String, int)>[])
        .map((e) => e.$1)
        .where((t) => !tags.contains(t))
        .take(6)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: input,
          style: JType.body.copyWith(fontSize: 15, color: c.ink),
          decoration: InputDecoration(
            hintText: 'Tags — trip, gift, work…',
            prefixIcon: Icon(Icons.sell_outlined, size: 17, color: c.inkFaint),
          ),
          onChanged: (v) {
            if (v.endsWith(',')) _commit();
          },
          onSubmitted: (_) => _commit(),
        ),
        if (tags.isNotEmpty || known.isNotEmpty) ...[
          const SizedBox(height: JSpace.sm),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in tags)
                JChip(
                  label: '#$t',
                  selected: true,
                  accent: JAccent.household,
                  leading: Icon(Icons.close_rounded, size: 13, color: c.household),
                  onTap: () => onChanged([...tags]..remove(t)),
                ),
              for (final t in known) JChip(label: '#$t', selected: false, onTap: () => onChanged([...tags, t])),
            ],
          ),
        ],
      ],
    );
  }
}

/// Receipt thumbnails for an entry plus an add tile. Saved receipts come
/// from the database (when editing); [pending] are picked but not yet saved.
class ReceiptsStrip extends ConsumerWidget {
  const ReceiptsStrip({
    required this.transactionId,
    required this.pending,
    required this.onAdd,
    required this.onRemovePending,
    super.key,
  });

  final String? transactionId;
  final List<PendingFile> pending;
  final VoidCallback onAdd;
  final ValueChanged<PendingFile> onRemovePending;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.jc;
    final saved = transactionId == null
        ? const <Attachment>[]
        : ref.watch(attachmentsProvider(transactionId!)).value ?? const <Attachment>[];
    return SizedBox(
      height: 64,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _Tile(
            onTap: onAdd,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.receipt_long_outlined, size: 18, color: c.inkFaint),
                const SizedBox(height: 4),
                Text('RECEIPT', style: JType.microLabel.copyWith(color: c.inkFaint, fontSize: 8.5)),
              ],
            ),
          ),
          for (final a in saved)
            _Tile(
              onTap: () => openAttachment(context, a),
              onLongPress: () => ref.read(ledgerProvider).deleteAttachment(a.id),
              child: _SavedThumb(attachment: a),
            ),
          for (final f in pending)
            _Tile(
              onLongPress: () => onRemovePending(f),
              onTap: () => onRemovePending(f),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(f.bytes, fit: BoxFit.cover),
                  Align(
                    alignment: Alignment.topRight,
                    child: Container(
                      margin: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                      child: const Icon(Icons.close_rounded, size: 13, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.child, this.onTap, this.onLongPress});

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    return Padding(
      padding: const EdgeInsets.only(right: JSpace.sm),
      child: Material(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            width: 64,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.hairline),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _SavedThumb extends StatelessWidget {
  const _SavedThumb({required this.attachment});

  final Attachment attachment;

  @override
  Widget build(BuildContext context) => FutureBuilder<File>(
    future: AttachmentStore.fileFor(attachment),
    builder: (context, snap) {
      final f = snap.data;
      if (f == null || !f.existsSync()) {
        return Icon(Icons.cloud_download_outlined, size: 18, color: context.jc.inkFaint);
      }
      return Image.file(f, fit: BoxFit.cover, cacheWidth: 160);
    },
  );
}

/// Full-screen receipt viewer with pinch-zoom and delete.
Future<void> openAttachment(BuildContext context, Attachment a) async {
  final f = await AttachmentStore.fileFor(a);
  if (!context.mounted) return;
  await Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(a.fileName, style: JType.chipLabel.copyWith(color: Colors.white)),
            actions: [
              IconButton(
                tooltip: 'Delete receipt',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () {
                  ref.read(ledgerProvider).deleteAttachment(a.id);
                  Navigator.of(ctx).pop();
                },
              ),
            ],
          ),
          body: Center(
            child: f.existsSync()
                ? InteractiveViewer(maxScale: 6, child: Image.file(f))
                : Text(
                    'Not downloaded yet — it arrives with the next sync.',
                    style: JType.body.copyWith(color: Colors.white70),
                  ),
          ),
        ),
      ),
    ),
  );
}
