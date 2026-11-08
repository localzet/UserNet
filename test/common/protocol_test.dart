import 'package:fl_clash/common/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('ProtocolRegistrationPlan', () {
    test('builds registry writes for URL protocol registration', () {
      const plan = ProtocolRegistrationPlan(
        scheme: 'flclash',
        executable: r'C:\Program Files\FlClash\FlClash.exe',
      );

      expect(plan.protocolKey, r'Software\Classes\flclash');
      expect(plan.commandKey, r'shell\open\command');
      expect(plan.protocolValueName, 'URL Protocol');
      expect(plan.protocolValue, '');
      expect(plan.command, r'"C:\Program Files\FlClash\FlClash.exe" "%1"');
    });
  });

  group('LinuxProtocolRegistrationPlan', () {
    const plan = LinuxProtocolRegistrationPlan(
      schemes: linuxProtocolSchemes,
      executable: '/home/me/Apps/UserNet.AppImage',
      applicationsDir: '/home/me/.local/share/applications',
    );

    test('writes an isolated hidden desktop entry', () {
      expect(
        plan.desktopPath,
        '/home/me/.local/share/applications/usernet-url-handler.desktop',
      );
      expect(
        plan.desktopEntry,
        '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=UserNet\n'
        'NoDisplay=true\n'
        'Exec="/home/me/Apps/UserNet.AppImage" %u\n'
        'MimeType=x-scheme-handler/usernet;\n',
      );
    });

    test('does not take over legacy schemes', () {
      expect(plan.xdgMimeArguments, [
        'default',
        'usernet-url-handler.desktop',
        'x-scheme-handler/usernet',
      ]);
      expect(supportedProtocolSchemes, containsAll(protocolSchemes));
      expect(supportedProtocolSchemes, contains('usernet'));
    });

    test('escapes reserved characters in the executable path', () {
      const plan = LinuxProtocolRegistrationPlan(
        schemes: ['flclash'],
        executable: r'/opt/my "apps"/$HOME/100%/Fl`Clash\bin',
        applicationsDir: '/tmp',
      );

      expect(plan.exec, r'"/opt/my \"apps\"/\$HOME/100%%/Fl\`Clash\\bin" %u');
    });
  });
}
