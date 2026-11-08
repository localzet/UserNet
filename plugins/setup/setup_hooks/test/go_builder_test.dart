import 'package:setup_hooks/src/go_builder.dart';
import 'package:test/test.dart';

void main() {
  group('GoCommandArguments', () {
    test('disables VCS stamping while listing dependency inputs', () {
      const template = '{{.Dir}}/{{.GoFiles}}';

      expect(
        GoCommandArguments.list(
          tags: 'with_gvisor',
          template: template,
          mainPackage: './cmd/core',
        ),
        [
          'list',
          '-buildvcs=false',
          '-deps',
          '-tags=with_gvisor',
          '-f',
          template,
          './cmd/core',
        ],
      );
    });

    test('disables VCS stamping while building and preserves output args', () {
      expect(
        GoCommandArguments.build(
          ldflags: '-w -s',
          tags: 'with_gvisor',
          mainPackage: './cmd/core',
          outFile: '/tmp/core',
        ),
        [
          'build',
          '-buildvcs=false',
          '-ldflags=-w -s',
          '-tags=with_gvisor',
          '-o',
          '/tmp/core',
          './cmd/core',
        ],
      );
    });
  });
}
