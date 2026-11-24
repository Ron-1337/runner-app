import 'package:material_ui/material_ui.dart';

import '../core/remote.dart';
import '../services.dart';

enum StartKind { chat, shell, mission }

/// What a start page produced: a session to open, or a mission that started.
class Started {
  Started({this.session, this.mission});
  final String? session;
  final String? mission;
}

/// Starts a chat, a terminal or a mission on the computer, in a workspace or folder.
class StartPage extends StatefulWidget {
  const StartPage({
    super.key,
    required this.remote,
    required this.kind,
    this.project,
    this.crew,
  });

  final Remote remote;
  final StartKind kind;

  /// The workspace to start in, when started from one.
  final String? project;

  /// The crew a mission starts with, when started from one.
  final String? crew;

  @override
  State<StartPage> createState() => _StartPageState();
}

class _StartPageState extends State<StartPage> {
  Map<String, dynamic>? _catalog;
  String? _error;
  var _busy = false;

  // Chat: a role, or a runtime with an optional model.
  var _byRole = true;
  String? _role;
  String? _runtime;
  String? _model;

  // Mission.
  String? _crew;
  final _title = TextEditingController();
  final _goal = TextEditingController();

  String? _project;
  String? _cwd;

  @override
  void initState() {
    super.initState();
    _project = widget.project;
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _goal.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final catalog = await widget.remote.catalog();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _role = _roles.firstOrNull?['id'] as String?;
        _byRole = _roles.isNotEmpty;
        _runtime = _runtimes.firstOrNull?['name'] as String?;
        _crew =
            _crews.where((c) => c['id'] == widget.crew).firstOrNull?['id']
                as String? ??
            _crews.firstOrNull?['id'] as String?;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  List<Map<String, dynamic>> _list(String key) =>
      ((_catalog?[key] as List?) ?? const []).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get _roles => _list('roles');
  List<Map<String, dynamic>> get _runtimes =>
      _list('runtimes').where((r) => r['available'] == true).toList();
  List<Map<String, dynamic>> get _crews => _list('crews');
  List<Map<String, dynamic>> get _projects => _list('projects');

  List<Map<String, dynamic>> get _models =>
      ((_runtimes.firstWhere(
                    (r) => r['name'] == _runtime,
                    orElse: () => const {},
                  )['models']
                  as List?) ??
              const [])
          .cast<Map<String, dynamic>>();

  String get _heading => switch (widget.kind) {
    StartKind.chat => '新建聊天',
    StartKind.shell => '新建终端',
    StartKind.mission => '新建任务',
  };

  bool get _ready => switch (widget.kind) {
    StartKind.chat => _byRole ? _role != null : _runtime != null,
    StartKind.shell => true,
    StartKind.mission => _crew != null && _title.text.trim().isNotEmpty,
  };

  Future<void> _start() async {
    setState(() => _busy = true);
    final place = {'project': _project, 'cwd': _cwd};
    const size = {'cols': startCols, 'rows': startRows};
    try {
      final Started started;
      switch (widget.kind) {
        case StartKind.chat:
          final result = await widget.remote.request('startChat', {
            'role': _byRole ? _role : null,
            'runtime': _byRole ? null : _runtime,
            'model': _byRole ? null : _model,
            'effort': null,
            'speed': null,
            ...place,
            ...size,
          });
          started = Started(session: (result as Map)['session'] as String);
        case StartKind.shell:
          final result = await widget.remote.request('startShell', {
            ...place,
            ...size,
          });
          started = Started(session: (result as Map)['session'] as String);
        case StartKind.mission:
          final goal = _goal.text.trim();
          final result = await widget.remote.request('startMission', {
            'crew': _crew,
            'title': _title.text.trim(),
            'goal': goal.isEmpty ? null : goal,
            ...place,
            ...size,
          });
          started = Started(mission: (result as Map)['mission'] as String);
      }
      if (mounted) Navigator.pop(context, started);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_heading)),
      body: _catalog == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Text(_error!),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ...switch (widget.kind) {
                  StartKind.chat => _chatFields(),
                  StartKind.shell => const <Widget>[],
                  StartKind.mission => _missionFields(),
                },
                ..._placeFields(),
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('start'),
                  onPressed: _busy || !_ready ? null : _start,
                  child: Text(_busy ? '正在启动…' : '启动'),
                ),
              ],
            ),
    );
  }

  List<Widget> _chatFields() => [
    if (_roles.isNotEmpty)
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: true, label: Text('角色')),
          ButtonSegment(value: false, label: Text('运行时')),
        ],
        selected: {_byRole},
        onSelectionChanged: (v) => setState(() => _byRole = v.first),
      ),
    const SizedBox(height: 12),
    if (_byRole)
      DropdownButtonFormField<String>(
        key: const Key('role'),
        initialValue: _role,
        decoration: const InputDecoration(labelText: '角色'),
        items: [
          for (final role in _roles)
            DropdownMenuItem(
              value: role['id'] as String,
              child: Text('${role['name']}（${role['runtime']}）'),
            ),
        ],
        onChanged: (v) => setState(() => _role = v),
      )
    else ...[
      DropdownButtonFormField<String>(
        key: const Key('runtime'),
        initialValue: _runtime,
        decoration: const InputDecoration(labelText: '运行时'),
        items: [
          for (final runtime in _runtimes)
            DropdownMenuItem(
              value: runtime['name'] as String,
              child: Text(
                runtime['label'] as String? ?? runtime['name'] as String,
              ),
            ),
        ],
        onChanged: (v) => setState(() {
          _runtime = v;
          _model = null;
        }),
      ),
      if (_models.isNotEmpty)
        DropdownButtonFormField<String?>(
          initialValue: _model,
          decoration: const InputDecoration(labelText: '模型'),
          items: [
            const DropdownMenuItem(value: null, child: Text('默认')),
            for (final model in _models)
              DropdownMenuItem(
                value: model['value'] as String,
                child: Text(
                  model['label'] as String? ?? model['value'] as String,
                ),
              ),
          ],
          onChanged: (v) => setState(() => _model = v),
        ),
    ],
  ];

  List<Widget> _missionFields() => [
    DropdownButtonFormField<String>(
      key: const Key('crew'),
      initialValue: _crew,
      decoration: const InputDecoration(labelText: '团队'),
      items: [
        for (final crew in _crews)
          DropdownMenuItem(
            value: crew['id'] as String,
            child: Text(crew['name'] as String),
          ),
      ],
      onChanged: (v) => setState(() => _crew = v),
    ),
    if (_crews.isEmpty)
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text('这台电脑上还没有团队，请先在电脑页的「团队」中新建。'),
      ),
    TextField(
      key: const Key('title'),
      controller: _title,
      decoration: const InputDecoration(labelText: '标题'),
      onChanged: (_) => setState(() {}),
    ),
    TextField(
      key: const Key('goal'),
      controller: _goal,
      minLines: 2,
      maxLines: 6,
      decoration: const InputDecoration(
        labelText: '目标（可选）',
        hintText: '留空则使用团队的默认目标',
      ),
    ),
  ];

  List<Widget> _placeFields() => [
    const SizedBox(height: 12),
    DropdownButtonFormField<String?>(
      key: const Key('project'),
      initialValue: _project,
      decoration: const InputDecoration(labelText: '工作区'),
      items: [
        const DropdownMenuItem(value: null, child: Text('不属于工作区')),
        for (final project in _projects)
          DropdownMenuItem(
            value: project['id'] as String,
            child: Text(project['name'] as String),
          ),
      ],
      onChanged: (v) => setState(() {
        _project = v;
        _cwd = null;
      }),
    ),
    ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('工作目录'),
      subtitle: Text(
        _cwd ??
            (_project == null
                ? '默认（角色或运行时的目录）'
                : '工作区目录：${_projects.firstWhere((p) => p['id'] == _project, orElse: () => const {})['path'] ?? ''}'),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_cwd != null)
            IconButton(
              tooltip: '使用默认',
              icon: const Icon(Icons.clear),
              onPressed: () => setState(() => _cwd = null),
            ),
          const Icon(Icons.folder_open),
        ],
      ),
      onTap: () async {
        final recent = ((_catalog?['recentFolders'] as List?) ?? const [])
            .cast<String>();
        final path = await pickFolder(context, widget.remote, recent: recent);
        if (path != null) setState(() => _cwd = path);
      },
    ),
  ];
}

/// Creates a workspace (a Runner project) from a folder on the computer.
class NewProjectPage extends StatefulWidget {
  const NewProjectPage({super.key, required this.remote});

  final Remote remote;

  @override
  State<NewProjectPage> createState() => _NewProjectPageState();
}

class _NewProjectPageState extends State<NewProjectPage> {
  final _name = TextEditingController();
  String? _path;
  var _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    final path = await pickFolder(context, widget.remote);
    if (path == null) return;
    setState(() {
      _path = path;
      if (_name.text.trim().isEmpty) {
        _name.text = path
            .split(RegExp(r'[/\\]'))
            .lastWhere((part) => part.isNotEmpty, orElse: () => path);
      }
    });
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final result = await widget.remote.request('createProject', {
        'name': _name.text.trim(),
        'path': _path,
      });
      if (mounted) Navigator.pop(context, (result as Map)['project'] as String);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _path != null && _name.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('新建工作区')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('文件夹'),
            subtitle: Text(_path ?? '选择电脑上的一个文件夹'),
            trailing: const Icon(Icons.folder_open),
            onTap: _choose,
          ),
          TextField(
            key: const Key('projectName'),
            controller: _name,
            decoration: const InputDecoration(labelText: '名称'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('create'),
            onPressed: _busy || !ready ? null : _create,
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }
}

/// Browses the computer's folders, starting from its home folder.
Future<String?> pickFolder(
  BuildContext context,
  Remote remote, {
  List<String> recent = const [],
}) => Navigator.of(context).push<String>(
  MaterialPageRoute(
    builder: (_) => FolderPage(remote: remote, recent: recent),
  ),
);

class FolderPage extends StatefulWidget {
  const FolderPage({super.key, required this.remote, this.recent = const []});

  final Remote remote;
  final List<String> recent;

  @override
  State<FolderPage> createState() => _FolderPageState();
}

class _FolderPageState extends State<FolderPage> {
  Map<String, dynamic>? _page;
  String? _error;

  /// Recent folders show until the person opens one.
  var _atStart = true;

  @override
  void initState() {
    super.initState();
    _open(null);
  }

  Future<void> _open(String? path) async {
    try {
      final page = await widget.remote.folders(path);
      if (mounted) {
        setState(() {
          _atStart = _page == null;
          _page = page;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    final path = page?['path'] as String?;
    final parent = page?['parent'] as String?;
    final folders = ((page?['folders'] as List?) ?? const []).cast<String>();
    return Scaffold(
      appBar: AppBar(
        title: Text(path ?? '选择文件夹', overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            key: const Key('chooseFolder'),
            onPressed: path == null ? null : () => Navigator.pop(context, path),
            child: const Text('选择'),
          ),
        ],
      ),
      body: page == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Text(_error!),
            )
          : ListView(
              children: [
                if (_error != null)
                  ListTile(
                    leading: const Icon(Icons.error_outline),
                    title: Text(_error!),
                  ),
                if (parent != null)
                  ListTile(
                    leading: const Icon(Icons.arrow_upward),
                    title: const Text('上一级'),
                    onTap: () => _open(parent),
                  ),
                if (_atStart && widget.recent.isNotEmpty) ...[
                  const ListTile(dense: true, title: Text('最近使用')),
                  for (final folder in widget.recent)
                    ListTile(
                      leading: const Icon(Icons.history),
                      title: Text(folder),
                      onTap: () => _open(folder),
                    ),
                  const Divider(),
                ],
                for (final name in folders)
                  ListTile(
                    leading: const Icon(Icons.folder),
                    title: Text(name),
                    onTap: () => _open(widget.remote.join(path!, name)),
                  ),
                if (folders.isEmpty) const ListTile(title: Text('没有子文件夹')),
              ],
            ),
    );
  }
}
