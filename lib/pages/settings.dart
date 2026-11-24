import 'package:material_ui/material_ui.dart';

import '../core/store.dart';
import '../services.dart';
import 'notifications.dart';
import 'terminal.dart'
    show defaultFontSize, maxFontSize, minFontSize, terminalStyle;

/// The app's settings: the terminal's font size and return key, the accounts,
/// and what this phone is.
class SettingsView extends StatefulWidget {
  const SettingsView({
    super.key,
    required this.accounts,
    required this.onAddAccount,
    required this.onSignInAgain,
    required this.onSignOut,
  });

  final List<Account> accounts;
  final VoidCallback onAddAccount;
  final ValueChanged<Account> onSignInAgain;
  final ValueChanged<Account> onSignOut;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  /// The accounts on runner-server, which pushes notifications.
  List<Account> get _notifiable => [
    for (final account in widget.accounts)
      if (!account.official) account,
  ];

  double _fontSize = defaultFontSize;
  var _typeface = TerminalFont.jetBrainsMono;
  var _cursor = TerminalCursor.block;
  var _cursorAlways = false;
  var _enterSends = false;
  Map<String, Object?> _device = knownDeviceInfo();
  var _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final store = Services.of(context).store;
    store.terminalFontSize().then((size) {
      if (mounted && size != null) setState(() => _fontSize = size);
    });
    store.terminalFont().then((font) {
      if (mounted) setState(() => _typeface = font);
    });
    store.terminalCursor().then((cursor) {
      if (mounted) setState(() => _cursor = cursor);
    });
    store.terminalCursorAlways().then((always) {
      if (mounted) setState(() => _cursorAlways = always);
    });
    store.keyboardEnterSends().then((sends) {
      if (mounted) setState(() => _enterSends = sends);
    });
    deviceInfo().then((device) {
      if (mounted) setState(() => _device = device);
    });
  }

  void _font(double size) {
    final clamped = size.clamp(minFontSize, maxFontSize).toDouble();
    setState(() => _fontSize = clamped);
    Services.of(context).store.setTerminalFontSize(clamped);
  }

  void _setFont(TerminalFont font) {
    setState(() => _typeface = font);
    Services.of(context).store.setTerminalFont(font);
  }

  void _setCursor(TerminalCursor cursor) {
    setState(() => _cursor = cursor);
    Services.of(context).store.setTerminalCursor(cursor);
  }

  void _setCursorAlways(bool always) {
    setState(() => _cursorAlways = always);
    Services.of(context).store.setTerminalCursorAlways(always);
  }

  bool get _terminalDefaults =>
      _fontSize == defaultFontSize &&
      _typeface == TerminalFont.jetBrainsMono &&
      _cursor == TerminalCursor.block &&
      !_cursorAlways;

  void _resetTerminal() {
    _font(defaultFontSize);
    _setFont(TerminalFont.jetBrainsMono);
    _setCursor(TerminalCursor.block);
    _setCursorAlways(false);
  }

  /// A line of terminal text in the chosen font, size and cursor.
  Widget _preview() {
    final colors = Theme.of(context).colorScheme;
    final cursor = switch (_cursor) {
      TerminalCursor.block => '█',
      TerminalCursor.underline => '_',
      TerminalCursor.bar => '▏',
    };
    return Container(
      key: const Key('settingsTerminalPreview'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '~/runner \$ claude --model opus 你好 $cursor',
        style: terminalStyle(
          _typeface,
          _fontSize,
        ).toTextStyle(color: colors.onSurface),
      ),
    );
  }

  void _enter(bool sends) {
    setState(() => _enterSends = sends);
    Services.of(context).store.setKeyboardEnterSends(sends);
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String text(String key) => _device[key] as String? ?? '';
    return ListView(
      key: const Key('settings'),
      children: [
        _heading('终端'),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              key: const Key('settingsFontReset'),
              onPressed: _terminalDefaults ? null : _resetTerminal,
              child: const Text('恢复默认'),
            ),
          ),
        ),
        _preview(),
        for (final font in TerminalFont.values)
          ListTile(
            key: Key('settingsFont.${font.name}'),
            title: Text(font.label),
            subtitle: Text(font.detail),
            leading: Icon(
              font == _typeface
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
            ),
            onTap: () => _setFont(font),
          ),
        ListTile(
          title: const Text('字体大小'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const Key('settingsFontSmaller'),
                tooltip: '缩小',
                icon: const Icon(Icons.text_decrease),
                onPressed: _fontSize > minFontSize
                    ? () => _font(_fontSize - 1)
                    : null,
              ),
              SizedBox(
                width: 32,
                child: Text(
                  _fontSize.round().toString(),
                  key: const Key('settingsFontSize'),
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                key: const Key('settingsFontLarger'),
                tooltip: '放大',
                icon: const Icon(Icons.text_increase),
                onPressed: _fontSize < maxFontSize
                    ? () => _font(_fontSize + 1)
                    : null,
              ),
            ],
          ),
        ),
        ListTile(
          title: const Text('光标'),
          trailing: SegmentedButton<TerminalCursor>(
            key: const Key('settingsCursor'),
            showSelectedIcon: false,
            segments: [
              for (final cursor in TerminalCursor.values)
                ButtonSegment(value: cursor, label: Text(cursor.label)),
            ],
            selected: {_cursor},
            onSelectionChanged: (selected) => _setCursor(selected.single),
          ),
        ),
        SwitchListTile(
          key: const Key('settingsCursorAlways'),
          title: const Text('始终显示光标'),
          subtitle: const Text('收起键盘时也显示'),
          value: _cursorAlways,
          onChanged: _setCursorAlways,
        ),
        ListTile(
          title: const Text('手机键盘的回车'),
          subtitle: Text(
            _enterSends ? '发送（按键栏的 Enter 也发送）' : '换行，用按键栏的 Enter 发送',
          ),
          trailing: SegmentedButton<bool>(
            key: const Key('enterSends'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('换行')),
              ButtonSegment(value: true, label: Text('发送')),
            ],
            selected: {_enterSends},
            onSelectionChanged: (selected) => _enter(selected.single),
          ),
        ),
        const Divider(),
        _heading('账户'),
        for (final account in widget.accounts)
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(account.label),
            subtitle: Text(
              '${account.origin}\n'
              '${account.official ? '官方服务器' : 'Runner-Server ${account.serverVersion}'}',
            ),
            isThreeLine: true,
            trailing: PopupMenuButton<String>(
              key: Key('settingsAccount.${account.id}'),
              onSelected: (action) => action == 'signInAgain'
                  ? widget.onSignInAgain(account)
                  : widget.onSignOut(account),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'signInAgain', child: Text('重新登录')),
                PopupMenuItem(value: 'signOut', child: Text('退出登录')),
              ],
            ),
          ),
        ListTile(
          key: const Key('settingsAddAccount'),
          leading: const Icon(Icons.person_add_alt),
          title: const Text('添加账户'),
          onTap: widget.onAddAccount,
        ),
        // Push notifications are runner-server's; the official service has none.
        if (_notifiable.isNotEmpty) ...[
          const Divider(),
          _heading('通知'),
          for (final account in _notifiable)
            ListTile(
              key: Key('settingsNotifications.${account.id}'),
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('推送通知'),
              subtitle: Text(
                _notifiable.length > 1 ? account.label : '会话需要输入、完成或失败时，由服务器推送',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NotificationsPage(account: account),
                ),
              ),
            ),
        ],
        const Divider(),
        _heading('关于'),
        ListTile(
          title: const Text('Runner Remote'),
          subtitle: Text('版本 ${text('appVersion')}'),
        ),
        ListTile(
          title: const Text('本机'),
          subtitle: Text(
            [
              text('name'),
              [
                text('platform'),
                text('osVersion'),
              ].where((s) => s.isNotEmpty).join(' '),
            ].where((s) => s.isNotEmpty).join(' · '),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          child: Text('登录服务器时可以修改这台手机的名称。', style: theme.textTheme.bodySmall),
        ),
      ],
    );
  }
}
