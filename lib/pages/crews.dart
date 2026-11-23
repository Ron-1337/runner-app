import 'package:material_ui/material_ui.dart';

import '../core/remote.dart';
import '../services.dart';
import 'start.dart';

/// Why [handle] cannot name a member of a crew whose other members are
/// [taken], or null when it can. Runner's own rule: lowercase letters, digits,
/// `-` or `_`, starting with a letter or digit, up to 32 characters.
String? slotHandleError(String handle, Iterable<String> taken) {
  if (handle.isEmpty) return '请填写代号';
  if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,31}$').hasMatch(handle)) {
    return '只能用小写字母、数字、- 或 _，以字母或数字开头，最多 32 个字符';
  }
  if (taken.contains(handle)) return '@$handle 已在这个团队中';
  return null;
}

/// [base], or `base-2`, `base-3`… when the crew already has it, as Runner suggests.
String suggestSlotHandle(String base, Iterable<String> taken) {
  final used = taken.toSet();
  if (!used.contains(base)) return base;
  for (var i = 2; i < 100; i++) {
    final candidate = '$base-$i';
    if (!used.contains(candidate)) return candidate;
  }
  return base;
}

/// The computer's crews: the teams missions run with, each a list of members
/// that take a role under their own @handle.
///
/// Pops with a [Started] when a mission was started from one of them.
class CrewsPage extends StatefulWidget {
  const CrewsPage({super.key, required this.remote});

  final Remote remote;

  @override
  State<CrewsPage> createState() => _CrewsPageState();
}

class _CrewsPageState extends State<CrewsPage> {
  List<Map<String, dynamic>>? _crews;
  String? _error;

  Remote get _remote => widget.remote;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final catalog = await _remote.catalog();
      if (!mounted) return;
      setState(() {
        _crews = ((catalog['crews'] as List?) ?? const [])
            .cast<Map<String, dynamic>>();
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _open(String crew) async {
    final started = await Navigator.of(context).push<Started>(
      MaterialPageRoute(
        builder: (_) => CrewPage(remote: _remote, crew: crew),
      ),
    );
    if (!mounted) return;
    if (started != null) {
      Navigator.pop(context, started);
      return;
    }
    await _load();
  }

  Future<void> _create() async {
    final edited = await editCrew(context);
    if (edited == null || !mounted) return;
    try {
      final result = await _remote.request('createCrew', {
        'name': edited.name,
        'conventions': edited.conventions,
      });
      if (!mounted) return;
      await _load();
      final id = (result as Map?)?['crew'] as String?;
      if (id != null && mounted) await _open(id);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final crews = _crews;
    return Scaffold(
      appBar: AppBar(title: const Text('团队')),
      floatingActionButton: _remote.has('createCrew') && crews != null
          ? FloatingActionButton.extended(
              key: const Key('newCrew'),
              onPressed: _remote.connected ? _create : null,
              icon: const Icon(Icons.group_add_outlined),
              label: const Text('新建团队'),
            )
          : null,
      body: Column(
        children: [
          ReconnectBanner(remote: _remote),
          Expanded(
            child: crews == null
                ? Center(
                    child: _error == null
                        ? const CircularProgressIndicator()
                        : Text(_error!),
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      children: [
                        if (crews.isEmpty)
                          const ListTile(
                            title: Text('这台电脑上还没有团队'),
                            subtitle: Text(
                              '团队由若干成员组成，每个成员以自己的 @代号 担任一个角色；新建任务时选择团队。',
                            ),
                          ),
                        for (final crew in crews)
                          ListTile(
                            key: Key('crew.${crew['id']}'),
                            leading: const Icon(Icons.groups_outlined),
                            title: Text(crew['name'] as String? ?? ''),
                            subtitle: Text(_members(crew)),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: _remote.has('crew')
                                ? () => _open(crew['id'] as String)
                                : null,
                          ),
                        const SizedBox(height: 80),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  static String _members(Map<String, dynamic> crew) {
    final handles = [
      for (final slot
          in ((crew['slots'] as List?) ?? const [])
              .cast<Map<String, dynamic>>())
        '@${slot['handle']}',
    ];
    return handles.isEmpty
        ? '还没有成员'
        : '${handles.length} 名成员 · ${handles.join(' ')}';
  }
}

/// A crew's name and conventions, as the person typed them.
class CrewFields {
  CrewFields(this.name, this.conventions);
  final String name;

  /// Shared instructions for every member; null when left empty.
  final String? conventions;
}

/// Asks for a crew's name and conventions, starting from [crew] when editing.
Future<CrewFields?> editCrew(
  BuildContext context, {
  Map<String, dynamic>? crew,
}) {
  final name = TextEditingController(text: crew?['name'] as String? ?? '');
  final conventions = TextEditingController(
    text: crew?['conventions'] as String? ?? '',
  );
  return showDialog<CrewFields>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, setState) => AlertDialog(
        title: Text(crew == null ? '新建团队' : '编辑团队'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('crewName'),
                controller: name,
                autofocus: crew == null,
                decoration: const InputDecoration(labelText: '名称'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('crewConventions'),
                controller: conventions,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: '约定（可选）',
                  hintText: '告诉每个成员的共同规则，例如“提交前先让 @reviewer 审查”',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('crewSave'),
            onPressed: name.text.trim().isEmpty
                ? null
                : () {
                    final text = conventions.text.trim();
                    Navigator.pop(
                      dialog,
                      CrewFields(name.text.trim(), text.isEmpty ? null : text),
                    );
                  },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
}

/// One crew: its conventions and members, which can be added, edited,
/// reordered and removed, and a mission started with it.
class CrewPage extends StatefulWidget {
  const CrewPage({super.key, required this.remote, required this.crew});

  final Remote remote;
  final String crew;

  @override
  State<CrewPage> createState() => _CrewPageState();
}

class _CrewPageState extends State<CrewPage> {
  Map<String, dynamic>? _crew;
  Map<String, dynamic>? _catalog;
  String? _error;
  var _busy = false;

  Remote get _remote => widget.remote;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _remote.request('crew', {'crew': widget.crew}),
        _remote.catalog(),
      ]);
      if (!mounted) return;
      setState(() {
        _crew = (results[0] as Map).cast<String, dynamic>();
        _catalog = results[1] as Map<String, dynamic>;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  List<Map<String, dynamic>> get _slots =>
      ((_crew?['slots'] as List?) ?? const []).cast<Map<String, dynamic>>();

  List<Map<String, dynamic>> _list(String key) =>
      ((_catalog?[key] as List?) ?? const []).cast<Map<String, dynamic>>();

  Map<String, dynamic>? _role(String? id) =>
      _list('roles').where((r) => r['id'] == id).firstOrNull;

  /// Runs [action] on the computer, then shows the crew as it is now.
  Future<bool> _act(Future<Object?> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
      return true;
    } catch (e) {
      if (mounted) showError(context, e);
      await _load();
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit() async {
    final edited = await editCrew(context, crew: _crew);
    if (edited == null || !mounted) return;
    await _act(
      () => _remote.request('updateCrew', {
        'crew': widget.crew,
        'name': edited.name,
        'conventions': edited.conventions,
      }),
    );
  }

  Future<void> _delete() async {
    final name = _crew?['name'] as String? ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('删除团队“$name”？'),
        content: const Text('团队和它的成员设置会从这台电脑上删除，已经开始的任务不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('crewDeleteConfirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _remote.request('deleteCrew', {'crew': widget.crew});
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        showError(context, e);
        setState(() => _busy = false);
      }
    }
  }

  Iterable<String> _handlesBut(String? slot) => [
    for (final s in _slots)
      if (s['id'] != slot) s['handle'] as String,
  ];

  Future<void> _addMember() async {
    final member = await showModalBottomSheet<SlotFields>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SlotForm(catalog: _catalog!, taken: _handlesBut(null)),
    );
    if (member == null || !mounted) return;
    await _act(
      () => _remote.request('addSlot', {
        'crew': widget.crew,
        'role': member.role,
        'handle': member.handle,
        'runtime': member.runtime,
        'model': member.model,
      }),
    );
  }

  Future<void> _editMember(Map<String, dynamic> slot) async {
    final member = await showModalBottomSheet<SlotFields>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SlotForm(
        catalog: _catalog!,
        taken: _handlesBut(slot['id'] as String),
        slot: slot,
      ),
    );
    if (member == null || !mounted) return;
    await _act(
      () => _remote.request('updateSlot', {
        'slot': slot['id'],
        'handle': member.handle,
        'runtime': member.runtime,
        'model': member.model,
        'effort': member.effort,
        'speed': member.speed,
      }),
    );
  }

  Future<void> _removeMember(Map<String, dynamic> slot) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('移除 @${slot['handle']}？'),
        content: const Text('之后用这个团队开始的任务不再有这个成员。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('slotRemoveConfirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _act(() => _remote.request('removeSlot', {'slot': slot['id']}));
  }

  /// Moves the member at [from] to [to], counted once it is out of the list.
  Future<void> _reorder(int from, int to) async {
    final slots = [..._slots];
    final moved = slots.removeAt(from);
    slots.insert(to, moved);
    // Shown at once; the computer's order replaces it after.
    setState(() => _crew = {...?_crew, 'slots': slots});
    await _act(
      () => _remote.request('reorderSlots', {
        'crew': widget.crew,
        'order': [for (final s in slots) s['id']],
      }),
    );
  }

  Future<void> _startMission() async {
    final started = await Navigator.of(context).push<Started>(
      MaterialPageRoute(
        builder: (_) => StartPage(
          remote: _remote,
          kind: StartKind.mission,
          crew: widget.crew,
        ),
      ),
    );
    if (started != null && mounted) Navigator.pop(context, started);
  }

  /// What a member runs as: the role, and what it overrides of it.
  String _summary(Map<String, dynamic> slot) {
    final role = _role(slot['role'] as String?);
    final overrides = [
      if (slot['runtime'] != null) _runtimeLabel(slot['runtime'] as String),
      slot['model'] as String?,
      if (slot['effort'] != null) '推理 ${slot['effort']}',
      if (slot['speed'] == 'fast') '快速',
    ].whereType<String>();
    return [
      role?['name'] as String? ?? '角色已删除',
      overrides.isEmpty ? '跟随角色设置' : overrides.join(' · '),
    ].join(' · ');
  }

  String _runtimeLabel(String name) =>
      _list('runtimes').where((r) => r['name'] == name).firstOrNull?['label']
          as String? ??
      name;

  @override
  Widget build(BuildContext context) {
    final crew = _crew;
    final live = _remote.connected && !_busy;
    return Scaffold(
      appBar: AppBar(
        title: Text(crew?['name'] as String? ?? '团队'),
        actions: [
          if (crew != null && _remote.has('updateCrew'))
            IconButton(
              key: const Key('crewEdit'),
              tooltip: '编辑团队',
              icon: const Icon(Icons.edit_outlined),
              onPressed: live ? _edit : null,
            ),
          if (crew != null && _remote.has('deleteCrew'))
            PopupMenuButton<String>(
              key: const Key('crewMenu'),
              enabled: live,
              onSelected: (_) => _delete(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'delete', child: Text('删除团队')),
              ],
            ),
        ],
      ),
      floatingActionButton:
          crew != null && _remote.has('addSlot') && _list('roles').isNotEmpty
          ? FloatingActionButton.extended(
              key: const Key('addSlot'),
              onPressed: live ? _addMember : null,
              icon: const Icon(Icons.person_add_alt),
              label: const Text('添加成员'),
            )
          : null,
      body: Column(
        children: [
          ReconnectBanner(remote: _remote),
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: crew == null
                ? Center(
                    child: _error == null
                        ? const CircularProgressIndicator()
                        : Text(_error!),
                  )
                : _members(crew, live),
          ),
        ],
      ),
    );
  }

  Widget _header(Map<String, dynamic> crew) {
    final theme = Theme.of(context);
    final conventions = crew['conventions'] as String?;
    return Column(
      key: const Key('crewHeader'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text('约定', style: theme.textTheme.titleSmall),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            conventions == null || conventions.isEmpty ? '未设置' : conventions,
            style: conventions == null || conventions.isEmpty
                ? theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  )
                : null,
          ),
        ),
        if (_remote.has('startMission'))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              key: const Key('crewStartMission'),
              onPressed: _remote.connected && _slots.isNotEmpty
                  ? _startMission
                  : null,
              icon: const Icon(Icons.play_arrow_outlined),
              label: const Text('用这个团队开始任务'),
            ),
          ),
        const Divider(height: 24),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            _slots.isEmpty
                ? '成员'
                : _remote.has('reorderSlots') && _slots.length > 1
                ? '成员（${_slots.length}）· 长按拖动排序'
                : '成员（${_slots.length}）',
            style: theme.textTheme.titleSmall,
          ),
        ),
        if (_slots.isEmpty)
          ListTile(
            title: const Text('还没有成员'),
            subtitle: Text(
              _list('roles').isEmpty
                  ? '这台电脑上还没有角色，请先在 Runner 中创建角色。'
                  : '点「添加成员」选一个角色，并给它起一个 @代号。',
            ),
          ),
      ],
    );
  }

  Widget _members(Map<String, dynamic> crew, bool live) {
    Widget tile(int index, Map<String, dynamic> slot) => ListTile(
      key: Key('slot.${slot['id']}'),
      leading: CircleAvatar(child: Text('${index + 1}')),
      title: Text('@${slot['handle']}'),
      subtitle: Text(_summary(slot)),
      onTap: live && _remote.has('updateSlot') ? () => _editMember(slot) : null,
      trailing: _remote.has('removeSlot')
          ? IconButton(
              key: Key('slotRemove.${slot['id']}'),
              tooltip: '移除',
              icon: const Icon(Icons.person_remove_outlined),
              onPressed: live ? () => _removeMember(slot) : null,
            )
          : null,
    );
    final slots = _slots;
    if (live && _remote.has('reorderSlots') && slots.length > 1) {
      return ReorderableListView(
        key: const Key('slots'),
        header: _header(crew),
        footer: const SizedBox(height: 80),
        buildDefaultDragHandles: false,
        onReorderItem: _reorder,
        children: [
          for (final (i, slot) in slots.indexed)
            ReorderableDelayedDragStartListener(
              key: ValueKey(slot['id']),
              index: i,
              child: tile(i, slot),
            ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const Key('slots'),
        children: [
          _header(crew),
          for (final (i, slot) in slots.indexed) tile(i, slot),
          const SizedBox(height: 80),
        ],
      ),
    );
  }
}

/// A member as the person set it: the role (when adding) and @handle, and
/// what it runs instead of the role's own settings (null keeps the role's).
class SlotFields {
  SlotFields({
    required this.role,
    required this.handle,
    this.runtime,
    this.model,
    this.effort,
    this.speed,
  });

  final String role;
  final String handle;
  final String? runtime;
  final String? model;
  final String? effort;
  final String? speed;
}

/// Adds a member to a crew, or edits [slot]. Pops with its [SlotFields].
class SlotForm extends StatefulWidget {
  const SlotForm({
    super.key,
    required this.catalog,
    required this.taken,
    this.slot,
  });

  final Map<String, dynamic> catalog;

  /// The other members' handles.
  final Iterable<String> taken;
  final Map<String, dynamic>? slot;

  @override
  State<SlotForm> createState() => _SlotFormState();
}

class _SlotFormState extends State<SlotForm> {
  late String? _role =
      widget.slot?['role'] as String? ?? _roles.firstOrNull?['id'] as String?;
  late final _handle = TextEditingController(
    text:
        widget.slot?['handle'] as String? ??
        _suggest(_roles.firstOrNull?['handle'] as String?),
  );
  late String? _runtime = widget.slot?['runtime'] as String?;
  late String? _model = widget.slot?['model'] as String?;
  late String? _effort = widget.slot?['effort'] as String?;
  late String? _speed = widget.slot?['speed'] as String?;

  bool get _adding => widget.slot == null;

  List<Map<String, dynamic>> _list(String key) =>
      ((widget.catalog[key] as List?) ?? const []).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get _roles => _list('roles');
  List<Map<String, dynamic>> get _runtimes =>
      _list('runtimes').where((r) => r['available'] == true).toList();

  Map<String, dynamic>? get _roleEntry =>
      _roles.where((r) => r['id'] == _role).firstOrNull;

  /// The runtime the member runs: its own, else its role's.
  String? get _effectiveRuntime =>
      _runtime ?? _roleEntry?['runtime'] as String?;

  Map<String, dynamic>? get _runtimeEntry => _list(
    'runtimes',
  ).where((r) => r['name'] == _effectiveRuntime).firstOrNull;

  List<Map<String, dynamic>> _options(Map<String, dynamic>? from, String key) =>
      ((from?[key] as List?) ?? const []).cast<Map<String, dynamic>>();

  List<Map<String, dynamic>> get _models => _options(_runtimeEntry, 'models');

  /// The efforts the chosen model takes, or the runtime's when it says none.
  List<Map<String, dynamic>> get _efforts {
    final all = _options(_runtimeEntry, 'efforts');
    final model = _models.where((m) => m['value'] == _model).firstOrNull;
    final supported = (model?['supportedEfforts'] as List?)?.cast<String>();
    return supported == null
        ? all
        : all.where((e) => supported.contains(e['value'])).toList();
  }

  List<String> get _speeds =>
      ((_runtimeEntry?['speeds'] as List?) ?? const []).cast<String>();

  String _suggest(String? base) =>
      base == null || base.isEmpty ? '' : suggestSlotHandle(base, widget.taken);

  String? get _handleError =>
      slotHandleError(_handle.text.trim(), widget.taken);

  @override
  void dispose() {
    _handle.dispose();
    super.dispose();
  }

  /// Keeps a choice only while the options still hold it.
  String? _keep(String? value, Iterable<Object?> values) =>
      values.contains(value) ? value : null;

  void _setRuntime(String? runtime) {
    setState(() {
      _runtime = runtime;
      _model = _keep(_model, _models.map((m) => m['value']));
      _effort = _keep(_effort, _efforts.map((e) => e['value']));
      _speed = _keep(_speed, _speeds);
    });
  }

  void _setRole(String? role) {
    final before = _roleEntry?['handle'] as String?;
    setState(() {
      _role = role;
      // A handle still the old role's suggestion follows the new role.
      if (_handle.text.trim().isEmpty ||
          _handle.text.trim() == _suggest(before)) {
        _handle.text = _suggest(_roleEntry?['handle'] as String?);
      }
    });
    _setRuntime(_runtime);
  }

  void _save() {
    Navigator.pop(
      context,
      SlotFields(
        role: _role!,
        handle: _handle.text.trim(),
        runtime: _runtime,
        model: _model,
        effort: _effort,
        speed: _speed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final role = _roleEntry;
    final roleRuntime = _list(
      'runtimes',
    ).where((r) => r['name'] == role?['runtime']).firstOrNull;
    final error = _handle.text.isEmpty ? null : _handleError;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _adding ? '添加成员' : '编辑 @${widget.slot!['handle']}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            if (_adding)
              DropdownButtonFormField<String>(
                key: const Key('slotRole'),
                initialValue: _role,
                decoration: const InputDecoration(labelText: '角色'),
                items: [
                  for (final r in _roles)
                    DropdownMenuItem(
                      value: r['id'] as String,
                      child: Text('${r['name']}（@${r['handle']}）'),
                    ),
                ],
                onChanged: _setRole,
              )
            else
              InputDecorator(
                decoration: const InputDecoration(labelText: '角色'),
                child: Text(role?['name'] as String? ?? '角色已删除'),
              ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('slotHandle'),
              controller: _handle,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: '代号',
                prefixText: '@',
                errorText: error,
                helperText: error == null ? '任务里用 @代号 称呼这个成员' : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              key: const Key('slotRuntime'),
              initialValue: _runtime,
              decoration: const InputDecoration(labelText: '运行时'),
              items: [
                DropdownMenuItem(
                  value: null,
                  child: Text(
                    '跟随角色（${roleRuntime?['label'] ?? role?['runtime'] ?? '—'}）',
                  ),
                ),
                for (final r in _runtimes)
                  DropdownMenuItem(
                    value: r['name'] as String,
                    child: Text(r['label'] as String? ?? r['name'] as String),
                  ),
              ],
              onChanged: _setRuntime,
            ),
            if (_models.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                key: Key('slotModel.$_effectiveRuntime'),
                initialValue: _model,
                decoration: const InputDecoration(labelText: '模型'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('跟随角色')),
                  for (final m in _models)
                    DropdownMenuItem(
                      value: m['value'] as String,
                      child: Text(
                        m['label'] as String? ?? m['value'] as String,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _model = v;
                  _effort = _keep(_effort, _efforts.map((e) => e['value']));
                }),
              ),
            ],
            // Runner takes effort and speed when editing a member, not when adding one.
            if (!_adding && _efforts.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                key: Key('slotEffort.$_effectiveRuntime.$_model'),
                initialValue: _effort,
                decoration: const InputDecoration(labelText: '推理强度'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('跟随角色')),
                  for (final e in _efforts)
                    DropdownMenuItem(
                      value: e['value'] as String,
                      child: Text(
                        e['label'] as String? ?? e['value'] as String,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _effort = v),
              ),
            ],
            if (!_adding && _speeds.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                key: Key('slotSpeed.$_effectiveRuntime'),
                initialValue: _speed,
                decoration: const InputDecoration(labelText: '速度'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('跟随角色')),
                  for (final s in _speeds)
                    DropdownMenuItem(
                      value: s,
                      child: Text(switch (s) {
                        'fast' => '快速',
                        'standard' => '标准',
                        _ => s,
                      }),
                    ),
                ],
                onChanged: (v) => setState(() => _speed = v),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              key: const Key('slotSave'),
              onPressed: _role == null || _handleError != null ? null : _save,
              child: Text(_adding ? '添加' : '保存'),
            ),
          ],
        ),
      ),
    );
  }
}
