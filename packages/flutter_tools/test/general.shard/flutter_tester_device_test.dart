// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:dds/dds.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/test/flutter_tester_device.dart';
import 'package:flutter_tools/src/test/font_config_manager.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/fake.dart';

import '../src/common.dart';
import '../src/context.dart';
import '../src/fake_process_manager.dart';

void main() {
  late FakePlatform platform;
  late FileSystem fileSystem;
  late FakeProcessManager processManager;
  late FlutterTesterTestDevice device;

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    // Not Windows.
    platform = FakePlatform(
      environment: <String, String>{},
    );
    processManager = FakeProcessManager.any();
  });

  FlutterTesterTestDevice createDevice({
    List<String> dartEntrypointArgs = const <String>[],
    bool enableObservatory = false,
  }) =>
    TestFlutterTesterDevice(
      platform: platform,
      fileSystem: fileSystem,
      processManager: processManager,
      enableObservatory: enableObservatory,
      dartEntrypointArgs: dartEntrypointArgs,
    );

  group('The FLUTTER_TEST environment variable is passed to the test process', () {
    setUp(() {
      processManager = FakeProcessManager.list(<FakeCommand>[]);
      device = createDevice();

      fileSystem
          .file('.dart_tool/package_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"configVersion":2,"packages":[]}');
    });

    FakeCommand flutterTestCommand(String expectedFlutterTestValue) {
      return FakeCommand(command: const <String>[
        '/',
        '--disable-observatory',
        '--ipv6',
        '--enable-checked-mode',
        '--verify-entry-points',
        '--enable-software-rendering',
        '--skia-deterministic-rendering',
        '--enable-dart-profiling',
        '--non-interactive',
        '--use-test-fonts',
        '--disable-asset-fonts',
        '--packages=.dart_tool/package_config.json',
        'example.dill',
      ], environment: <String, String>{
        'FLUTTER_TEST': expectedFlutterTestValue,
        'FONTCONFIG_FILE': device.fontConfigManager.fontConfigFile.path,
        'SERVER_PORT': '0',
        'APP_NAME': '',
      });
    }

    testUsingContext('as true when not originally set', () async {
      processManager.addCommand(flutterTestCommand('true'));

      await device.start('example.dill');
      expect(processManager, hasNoRemainingExpectations);
    });

    testUsingContext('as true when set to true', () async {
      platform.environment = <String, String>{'FLUTTER_TEST': 'true'};
      processManager.addCommand(flutterTestCommand('true'));

      await device.start('example.dill');
      expect(processManager, hasNoRemainingExpectations);
    });

    testUsingContext('as false when set to false', () async {
      platform.environment = <String, String>{'FLUTTER_TEST': 'false'};
      processManager.addCommand(flutterTestCommand('false'));

      await device.start('example.dill');
      expect(processManager, hasNoRemainingExpectations);
    });

    testUsingContext('unchanged when set', () async {
      platform.environment = <String, String>{'FLUTTER_TEST': 'neither true nor false'};
      processManager.addCommand(flutterTestCommand('neither true nor false'));

      await device.start('example.dill');
      expect(processManager, hasNoRemainingExpectations);
    });
  });

  group('Dart Entrypoint Args', () {
    setUp(() {
      processManager = FakeProcessManager.list(<FakeCommand>[
        const FakeCommand(
          command: <String>[
            '/',
            '--disable-observatory',
            '--ipv6',
            '--enable-checked-mode',
            '--verify-entry-points',
            '--enable-software-rendering',
            '--skia-deterministic-rendering',
            '--enable-dart-profiling',
            '--non-interactive',
            '--use-test-fonts',
            '--disable-asset-fonts',
            '--packages=.dart_tool/package_config.json',
            '--foo',
            '--bar',
            'example.dill',
          ],
          stdout: 'success',
          stderr: 'failure',
        ),
      ]);
      device = createDevice(dartEntrypointArgs: <String>['--foo', '--bar']);
    });

    testUsingContext('Can pass additional arguments to tester binary', () async {
      await device.start('example.dill');

      expect(processManager, hasNoRemainingExpectations);
    });
  });

  group('DDS', () {
    setUp(() {
      processManager = FakeProcessManager.list(<FakeCommand>[
        const FakeCommand(
          command: <String>[
            '/',
            '--observatory-port=0',
            '--ipv6',
            '--enable-checked-mode',
            '--verify-entry-points',
            '--enable-software-rendering',
            '--skia-deterministic-rendering',
            '--enable-dart-profiling',
            '--non-interactive',
            '--use-test-fonts',
            '--disable-asset-fonts',
            '--packages=.dart_tool/package_config.json',
            'example.dill',
          ],
          stdout: 'The Dart VM service is listening on http://localhost:1234',
          stderr: 'failure',
        ),
      ]);
      device = createDevice(enableObservatory: true);
    });

    testUsingContext('skips setting observatory port and uses the input port for DDS instead', () async {
      await device.start('example.dill');
      await device.observatoryUri;

      final Uri uri = await (device as TestFlutterTesterDevice).ddsServiceUriFuture();
      expect(uri.port, 1234);
    });
  });
}

/// A Flutter Tester device.
///
/// Uses a mock HttpServer. We don't want to bind random ports in our CI hosts.
class TestFlutterTesterDevice extends FlutterTesterTestDevice {
  TestFlutterTesterDevice({
    required super.platform,
    required super.fileSystem,
    required super.processManager,
    required super.enableObservatory,
    required List<String> dartEntrypointArgs,
  }) : super(
    id: 999,
    shellPath: '/',
    logger: BufferLogger.test(),
    debuggingOptions: DebuggingOptions.enabled(
      const BuildInfo(
        BuildMode.debug,
        '',
        treeShakeIcons: false,
      ),
      hostVmServicePort: 1234,
      dartEntrypointArgs: dartEntrypointArgs,
    ),
    machine: false,
    host: InternetAddress.loopbackIPv6,
    testAssetDirectory: null,
    flutterProject: null,
    icudtlPath: null,
    compileExpression: null,
    fontConfigManager: FontConfigManager(),
  );

  final Completer<Uri> _ddsServiceUriCompleter = Completer<Uri>();

  Future<Uri> ddsServiceUriFuture() => _ddsServiceUriCompleter.future;

  @override
  Future<DartDevelopmentService> startDds(Uri uri) async {
    _ddsServiceUriCompleter.complete(uri);
    return FakeDartDevelopmentService(Uri.parse('http://localhost:${debuggingOptions.hostVmServicePort}'), Uri.parse('http://localhost:8080'));
  }

  @override
  Future<HttpServer> bind(InternetAddress? host, int port) async => FakeHttpServer();

  @override
  Future<StreamChannel<String>> get remoteChannel async => StreamChannelController<String>().foreign;
}

class FakeDartDevelopmentService extends Fake implements DartDevelopmentService {
  FakeDartDevelopmentService(this.uri, this.original);

  final Uri original;

  @override
  final Uri uri;

  @override
  Uri get remoteVmServiceUri => original;
}
class FakeHttpServer extends Fake implements HttpServer {
  @override
  int get port => 0;
}
