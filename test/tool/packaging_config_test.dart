import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('Linux packaging teardown', () {
    for (final format in ['deb', 'rpm']) {
      test('$format removes the Helper unit only on a real uninstall', () {
        final config =
            loadYaml(
                  File(
                    'linux/packaging/$format/make_config.yaml',
                  ).readAsStringSync(),
                )
                as YamlMap;
        final scripts = (config['postuninstall_scripts'] as YamlList)
            .cast<String>();

        expect(scripts.first, contains('exit 0'));
        expect(
          scripts,
          contains('rm -f /etc/systemd/system/usernet-helper.service'),
        );
        expect(scripts.join('\n'), isNot(contains('flclashx-helper')));
        expect(
          scripts.any((script) => script.contains('systemctl daemon-reload')),
          isTrue,
        );
      });
    }
  });

  test('every Linux package names the GTK application id as its window '
      'class', () {
    final applicationId = RegExp(
      r'set\(APPLICATION_ID "([^"]+)"\)',
    ).firstMatch(File('linux/CMakeLists.txt').readAsStringSync())!.group(1);

    for (final format in ['deb', 'rpm', 'appimage']) {
      final config =
          loadYaml(
                File(
                  'linux/packaging/$format/make_config.yaml',
                ).readAsStringSync(),
              )
              as YamlMap;
      expect(config['startup_wm_class'], applicationId, reason: format);
      expect(config['supported_mime_type'], ['x-scheme-handler/usernet']);
    }
    expect(applicationId, 'com.localzet.usernet');
  });

  test(
    'Linux package metadata gives app stores the UserNet identity and logo',
    () {
      const applicationId = 'com.localzet.usernet';
      final metainfo = File(
        'linux/packaging/$applicationId.metainfo.xml',
      ).readAsStringSync();

      expect(metainfo, contains('<id>$applicationId</id>'));
      expect(metainfo, contains('<pkgname>usernet</pkgname>'));
      expect(metainfo, contains('<developer id="com.localzet">'));
      expect(metainfo, contains('<name>UserLay</name>'));
      expect(metainfo, contains('<developer_name>UserLay</developer_name>'));
      expect(metainfo, contains('https://www.userlay.com/usernet/'));
      expect(metainfo, contains('<icon type="stock">$applicationId</icon>'));
      expect(
        metainfo,
        contains('официальное настольное приложение Aura Network'),
      );
      expect(metainfo, contains('не связываются с аккаунтом Aura Network'));
      final icon = File('assets/images/usernet_icon.svg').readAsStringSync();
      expect(icon, contains('M64 43 L40 86 L88 86 Z'));
      expect(icon, contains('fill="#21A6EF"'));

      for (final format in ['deb', 'rpm', 'appimage']) {
        final config =
            loadYaml(
                  File(
                    'linux/packaging/$format/make_config.yaml',
                  ).readAsStringSync(),
                )
                as YamlMap;
        expect(config['desktop_icon'], applicationId, reason: format);
        expect(config['icon'], './assets/images/usernet_icon.svg');
        expect(config['comment'], contains('Aura Network'), reason: format);
        expect(config['generic_name'], 'VPN client', reason: format);
        expect(config['generic_name_ru'], 'VPN-клиент', reason: format);
      }
    },
  );

  test('Linux helper and app use the same isolated socket', () {
    final helper = File(
      'services/helper/src/service/linux.rs',
    ).readAsStringSync();
    final constants = File('lib/common/constant.dart').readAsStringSync();
    expect(helper, contains('"/run/usernet/helper.sock"'));
    expect(constants, contains("'/run/usernet/helper.sock'"));
    expect(helper, contains('"/etc/systemd/system/usernet-helper.service"'));
    expect(helper, isNot(contains('/run/flclashx/')));
  });

  test('rpm keeps the Core bytes the Helper was built against', () {
    final config =
        loadYaml(
              File('linux/packaging/rpm/make_config.yaml').readAsStringSync(),
            )
            as YamlMap;
    final macros = (config['spec_macros'] as YamlList).cast<String>();

    expect(macros, contains('%global debug_package %{nil}'));
    expect(macros, contains('%global __os_install_post %{nil}'));
  });
}
