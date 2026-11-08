import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (input.userDefines['build_assets'] == false) {
      stdout.writeln('Skipping the Rust build: user-define build_assets=false');
      return;
    }
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      extraCargoEnvironmentVariables: await _bindgenEnvironment(input),
    ).run(input: input, output: output);
  });
}

// rquickjs runs bindgen on Android, which must load the NDK's libclang; Linux
// NDKs before r26 keep it under lib64, later ones and every macOS NDK under lib.
Future<Map<String, String>> _bindgenEnvironment(BuildInput input) async {
  if (!input.config.buildCodeAssets ||
      input.config.code.targetOS != OS.android) {
    return const {};
  }
  final compiler = input.config.code.cCompiler?.compiler;
  if (compiler == null) {
    return const {};
  }
  final llvmRoot = File.fromUri(compiler).parent.parent;
  final resourceDirectory = await Process.run(compiler.toFilePath(), const [
    '-print-resource-dir',
  ]);
  if (resourceDirectory.exitCode != 0) {
    throw StateError('Unable to locate the NDK Clang resource directory.');
  }
  final clangInclude = Directory(
    '${resourceDirectory.stdout.toString().trim()}${Platform.pathSeparator}include',
  );
  if (!File(
    '${clangInclude.path}${Platform.pathSeparator}stdbool.h',
  ).existsSync()) {
    throw StateError('NDK Clang resource headers are missing.');
  }
  final code = input.config.code;
  final targetTriple = switch (code.targetArchitecture) {
    Architecture.arm => 'armv7-linux-androideabi',
    Architecture.arm64 => 'aarch64-linux-android',
    Architecture.ia32 => 'i686-linux-android',
    Architecture.x64 => 'x86_64-linux-android',
    final architecture => throw StateError(
      'Unsupported Android Rust architecture: $architecture',
    ),
  };
  final sysrootTriple = switch (targetTriple) {
    'armv7-linux-androideabi' => 'arm-linux-androideabi',
    _ => targetTriple,
  };
  final sysroot = '${llvmRoot.path}${Platform.pathSeparator}sysroot';
  final bindgenArgs =
      '--sysroot=$sysroot '
      '-I$sysroot/usr/include/$sysrootTriple '
      '-I${clangInclude.path}';
  for (final name in const ['lib', 'lib64']) {
    final directory = Directory(
      '${llvmRoot.path}${Platform.pathSeparator}$name',
    );
    if (directory.existsSync() && directory.listSync().any(_isLibclang)) {
      return {
        'LIBCLANG_PATH': directory.path,
        'BINDGEN_EXTRA_CLANG_ARGS_${targetTriple.replaceAll('-', '_')}':
            bindgenArgs,
      };
    }
  }
  throw StateError(
    'No libclang under ${llvmRoot.path} (lib or lib64); the NDK Flutter '
    'passed cannot run bindgen for rquickjs',
  );
}

bool _isLibclang(FileSystemEntity entity) {
  return entity.path.split(Platform.pathSeparator).last.startsWith('libclang.');
}
