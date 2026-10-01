import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:juno/core/category_style.dart';
import 'package:juno/core/db/database.dart';
import 'package:juno/core/providers.dart';
import 'package:juno/core/ui/ui.dart';
import 'package:juno/features/add/entry_sheet.dart' show ScopeToggle;

class CategoriesScreen extends ConsumerStatefulWidget {
  const CategoriesScreen({super.key});

  @override
  ConsumerState<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends ConsumerState<CategoriesScreen> {
  CategoryKind _kind = CategoryKind.expense;

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final all = ref.watch(allCategoriesProvider).value ?? const <Category>[];
    final list = all.where((k) => k.kind == _kind).toList();

    return JScreen(
      eyebrow: 'Settings · Categories',
      title: 'Name the *buckets*',
      subtitle: 'Drag to reorder. Default scope decides where new entries land.',
      actions: [
        JIconButton(icon: Icons.arrow_back_rounded, tooltip: 'Back', onPressed: () => Navigator.of(context).maybePop()),
        JIconButton(
          icon: Icons.add_rounded,
          tooltip: 'New category',
          onPressed: () => editCategory(context, kind: _kind),
        ),
      ],
      header: JSegmentBar<CategoryKind>(
        segments: const {CategoryKind.expense: 'Spending', CategoryKind.income: 'Income'},
        selected: _kind,
        accentOf: (k) => k == CategoryKind.income ? JAccent.income : JAccent.brand,
        onChanged: (k) => setState(() => _kind = k),
      ),
      slivers: [
        SliverReorderableList(
          itemCount: list.length,
          onReorder: (from, to) {
            final ids = [for (final k in list) k.id];
            final moved = ids.removeAt(from);
            ids.insert(to > from ? to - 1 : to, moved);
            ref.read(ledgerProvider).reorderCategories(ids);
          },
          itemBuilder: (context, i) {
            final k = list[i];
            final color = seriesColor(c, k.colorIndex);
            return ReorderableDelayedDragStartListener(
              key: ValueKey(k.id),
              index: i,
              child: Material(
                color: c.bg,
                child: Column(
                  children: [
                    InkWell(
                      onTap: () => editCategory(context, category: k),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: c.tint(color),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: color.withValues(alpha: 0.3)),
                              ),
                              child: Icon(categoryIcon(k.icon), size: 18, color: color),
                            ),
                            const SizedBox(width: JSpace.md),
                            Expanded(
                              child: Text(
                                k.archived ? '${k.name} (archived)' : k.name,
                                style: JType.rowTitle.copyWith(color: k.archived ? c.inkFaint : c.ink),
                              ),
                            ),
                            if (k.kind == CategoryKind.expense)
                              JPill(
                                k.defaultScope.label,
                                color: k.defaultScope == Scope.household ? c.household : c.brand,
                              ),
                            const SizedBox(width: JSpace.sm),
                            ReorderableDragStartListener(
                              index: i,
                              child: Icon(Icons.drag_indicator_rounded, size: 18, color: c.inkFaint),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Divider(color: c.hairline),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

Future<void> editCategory(BuildContext context, {Category? category, CategoryKind kind = CategoryKind.expense}) =>
    showJSheet<void>(
      context,
      title: category == null ? 'New *category*' : 'Edit *category*',
      child: _CategoryForm(category: category, kind: category?.kind ?? kind),
    );

class _CategoryForm extends ConsumerStatefulWidget {
  const _CategoryForm({required this.kind, this.category});

  final Category? category;
  final CategoryKind kind;

  @override
  ConsumerState<_CategoryForm> createState() => _CategoryFormState();
}

class _CategoryFormState extends ConsumerState<_CategoryForm> {
  late final _name = TextEditingController(text: widget.category?.name ?? '');
  late String _icon = widget.category?.icon ?? 'dots';
  late int _color = widget.category?.colorIndex ?? 0;
  late Scope _scope = widget.category?.defaultScope ?? Scope.personal;
  late bool _archived = widget.category?.archived ?? false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.jc;
    final color = seriesColor(c, _color);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        JField(
          label: 'Name',
          child: TextField(
            controller: _name,
            autofocus: widget.category == null,
            textCapitalization: TextCapitalization.sentences,
          ),
        ),
        JField(
          label: 'Icon',
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final e in categoryIcons.entries)
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => setState(() => _icon = e.key),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: e.key == _icon ? c.tint(color) : null,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: e.key == _icon ? color : c.hairline),
                    ),
                    child: Icon(e.value, size: 18, color: e.key == _icon ? color : c.inkMuted),
                  ),
                ),
            ],
          ),
        ),
        JField(
          label: 'Colour',
          child: Wrap(
            spacing: 10,
            children: [
              for (var i = 0; i < seriesCount; i++)
                GestureDetector(
                  onTap: () => setState(() => _color = i),
                  child: Container(
                    width: 30,
                    height: 30,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: i == _color ? c.ink : Colors.transparent, width: 1.5),
                    ),
                    child: JDot(seriesColor(c, i), size: 22),
                  ),
                ),
            ],
          ),
        ),
        if (widget.kind == CategoryKind.expense)
          JField(
            label: 'Default scope',
            child: Align(
              alignment: Alignment.centerLeft,
              child: ScopeToggle(value: _scope, onChanged: (s) => setState(() => _scope = s)),
            ),
          ),
        if (widget.category != null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Archived', style: JType.rowTitle.copyWith(color: c.ink)),
            subtitle: Text('Hidden from the add sheet, history kept', style: JType.body.copyWith(color: c.inkFaint)),
            value: _archived,
            onChanged: (v) => setState(() => _archived = v),
          ),
        const SizedBox(height: JSpace.sm),
        ListenableBuilder(
          listenable: _name,
          builder: (context, _) => JButton(
            label: 'Save category',
            expand: true,
            onPressed: _name.text.trim().isEmpty
                ? null
                : () async {
                    final existing = ref.read(allCategoriesProvider).value ?? const <Category>[];
                    await ref
                        .read(ledgerProvider)
                        .upsertCategory(
                          CategoriesCompanion(
                            id: widget.category == null ? const Value.absent() : Value(widget.category!.id),
                            name: Value(_name.text.trim()),
                            icon: Value(_icon),
                            colorIndex: Value(_color),
                            kind: Value(widget.kind),
                            defaultScope: Value(_scope),
                            archived: Value(_archived),
                            sort: Value(widget.category?.sort ?? existing.length),
                          ),
                        );
                    if (context.mounted) Navigator.of(context).pop();
                  },
          ),
        ),
      ],
    );
  }
}
