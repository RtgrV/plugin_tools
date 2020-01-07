// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart';
import 'package:path/path.dart' as p;
import 'package:platform/platform.dart';

import 'common.dart';

typedef void Print(Object object);

/// Lint the CocoaPod podspecs, run the static analyzer on iOS/macOS plugin
/// platform code, and run unit tests.
///
/// See https://guides.cocoapods.org/terminal/commands.html#pod_lib_lint.
class LintPodspecsCommand extends PluginCommand {
  LintPodspecsCommand(
    Directory packagesDir,
    FileSystem fileSystem, {
    ProcessRunner processRunner = const ProcessRunner(),
    this.platform = const LocalPlatform(),
    Print print = print,
  })  : _print = print,
        super(packagesDir, fileSystem, processRunner: processRunner) {
    argParser.addMultiOption('skip',
        help:
            'Skip all linting for podspecs with this basename (example: federated plugins with placeholder podspecs)',
        valueHelp: 'podspec_file_name');
    argParser.addMultiOption('no-analyze',
        help:
            'Do not pass --analyze flag to "pod lib lint" for podspecs with this basename (example: plugins with known analyzer warnings)',
        valueHelp: 'podspec_file_name');
  }

  @override
  final String name = 'podspecs';

  @override
  List<String> get aliases => <String>['podspec'];

  @override
  final String description =
      'Runs "pod lib lint" on all iOS and macOS plugin podspecs.\n\n'
      'This command requires "pod" and "flutter" to be in your path. Runs on macOS only.';

  final Platform platform;

  final Print _print;

  @override
  Future<Null> run() async {
    if (!platform.isMacOS) {
      _print('Detected platform is not macOS, skipping podspec lint');
      return;
    }

    checkSharding();

    await processRunner.runAndExitOnError('which', <String>['pod'],
        workingDir: packagesDir);

    _print('Starting podspec lint test');

    final List<String> failingPlugins = <String>[];
    for (File podspec in await _podspecsToLint()) {
      if (!await _lintPodspec(podspec)) {
        failingPlugins.add(p.basenameWithoutExtension(podspec.path));
      }
    }

    _print('\n\n');
    if (failingPlugins.isNotEmpty) {
      _print('The following plugins have podspec errors (see above):');
      failingPlugins.forEach((String plugin) {
        _print(' * $plugin');
      });
      throw ToolExit(1);
    }
  }

  Future<List<File>> _podspecsToLint() async {
    final List<File> podspecs = await getFiles().where((File entity) {
      final String filePath = entity.path;
      return p.extension(filePath) == '.podspec' &&
          !argResults['skip'].contains(p.basenameWithoutExtension(filePath));
    }).toList();

    podspecs.sort(
        (File a, File b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return podspecs;
  }

  Future<bool> _lintPodspec(File podspec) async {
    // Do not run the static analyzer on plugins with known analyzer issues.
    final String podspecPath = podspec.path;
    final bool runAnalyzer = !argResults['no-analyze']
        .contains(p.basenameWithoutExtension(podspecPath));

    final String podspecBasename = p.basename(podspecPath);
    if (runAnalyzer) {
      _print('Linting and analyzing $podspecBasename');
    } else {
      _print('Linting $podspecBasename');
    }

    // Lint two at a time.
    final Iterable<ProcessResult> results =
        await Future.wait(<Future<ProcessResult>>[
      // Lint plugin as framework (use_frameworks!).
      _runPodLint(podspecPath, runAnalyzer: runAnalyzer, libraryLint: true),

      // Lint plugin as library.
      _runPodLint(podspecPath, runAnalyzer: runAnalyzer, libraryLint: false)
    ]);

    for (ProcessResult result in results) {
      _print(result.stdout);
      _print(result.stderr);
    }

    return results.every((ProcessResult result) => result.exitCode == 0);
  }

  Future<ProcessResult> _runPodLint(String podspecPath,
      {bool runAnalyzer, bool libraryLint}) async {
    final List<String> arguments = <String>[
      'lib',
      'lint',
      podspecPath,
      '--allow-warnings',
      if (runAnalyzer) '--analyze',
      if (libraryLint) '--use-libraries'
    ];

    return processRunner.run('pod', arguments,
        workingDir: packagesDir, stdoutEncoding: utf8, stderrEncoding: utf8);
  }
}
