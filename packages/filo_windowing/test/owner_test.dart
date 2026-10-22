// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:ui' show FlutterView, Offset, Rect, Size;

import 'package:filo_windowing/filo_windowing.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_positioner.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeBackend backend;
  late FlutterView view;
  late FiloWindowingOwner owner;

  setUp(() {
    backend = FakeBackend();
    view = WidgetsBinding.instance.platformDispatcher.views.first;
    owner = installFiloWindowing(
      backend: backend,
      viewResolver: (_) => view,
    );
  });

  test('a regular window adopts the implicit view and forwards its request', () {
    final delegate = _RegularDelegate();
    final controller = owner.createRegularWindowController(
      delegate: delegate,
      size: const Size(800, 600),
      constraints: const BoxConstraints(minWidth: 320, minHeight: 240),
      title: 'hello',
      resizable: true,
    );

    expect(controller.rootView, same(view));
    expect(backend.lastViewId, 0);

    final request = backend.requests.single;
    expect(request.kind, FiloWindowKind.toplevel);
    expect(request.size, const Size(800, 600));
    expect(
      request.constraints,
      const BoxConstraints(minWidth: 320, minHeight: 240),
    );
    expect(request.title, 'hello');
    expect(request.preferredViewId, 0);
    expect(request.parentViewId, -1);
  });

  test('close requests go to the delegate', () {
    final delegate = _RegularDelegate();
    owner.createRegularWindowController(
      delegate: delegate,
      size: const Size(100, 100),
      resizable: true,
    );

    backend.emit(FiloWindowCloseRequested(backend.lastViewId!));
    expect(delegate.closeRequests, 1);
  });

  test('destroyed events mark the controller and notify the delegate', () {
    final delegate = _RegularDelegate();
    final controller = owner.createRegularWindowController(
      delegate: delegate,
      size: const Size(100, 100),
      resizable: true,
    );
    var notified = 0;
    controller.addListener(() => notified++);

    backend.emit(FiloWindowDestroyed(backend.lastViewId!));

    expect(delegate.destroyed, 1);
    expect(notified, 1);
    expect(controller.contentSize, Size.zero);
  });

  test('destroy asks the backend and reports the async destruction', () async {
    final delegate = _RegularDelegate();
    final controller = owner.createRegularWindowController(
      delegate: delegate,
      size: const Size(100, 100),
      resizable: true,
    );
    final id = backend.lastViewId!;

    controller.destroy();
    expect(backend.calls, contains('destroy:$id'));

    await pumpEventQueue();
    expect(delegate.destroyed, 1);
  });

  test('state changes notify listeners', () {
    final delegate = _RegularDelegate();
    final controller = owner.createRegularWindowController(
      delegate: delegate,
      size: const Size(100, 100),
      resizable: true,
    );
    final id = backend.lastViewId!;
    var notified = 0;
    controller.addListener(() => notified++);

    backend.states[id] = {FiloToplevelState.activated};
    backend.emit(
      FiloWindowStateChanged(
        id,
        toplevelState: {FiloToplevelState.activated},
      ),
    );

    expect(notified, 1);
    expect(controller.isActivated, isTrue);
  });

  test('setTitle updates the backend and notifies', () {
    final delegate = _RegularDelegate();
    final controller = owner.createRegularWindowController(
      delegate: delegate,
      size: const Size(100, 100),
      title: 'before',
      resizable: true,
    );
    final id = backend.lastViewId!;
    var notified = 0;
    controller.addListener(() => notified++);

    controller.setTitle('after');

    expect(backend.titles[id], 'after');
    expect(controller.title, 'after');
    expect(notified, 1);
  });

  test('a dialog is a parented toplevel', () {
    final regular = owner.createRegularWindowController(
      delegate: _RegularDelegate(),
      size: const Size(100, 100),
      resizable: true,
    );
    final regularId = backend.lastViewId!;

    final dialog = owner.createDialogWindowController(
      delegate: _DialogDelegate(),
      size: const Size(400, 300),
      parent: regular,
      title: 'dialog',
      resizable: true,
    );

    expect(dialog.parent, same(regular));
    expect(dialog.rootView, same(view));

    final request = backend.requests.last;
    expect(request.kind, FiloWindowKind.toplevel);
    expect(request.parentViewId, regularId);
    expect(request.modal, isTrue);
    expect(request.title, 'dialog');
  });

  test('a popup maps the positioner onto the backend request', () {
    final regular = owner.createRegularWindowController(
      delegate: _RegularDelegate(),
      size: const Size(100, 100),
      resizable: true,
    );
    final regularId = backend.lastViewId!;

    final popup = owner.createPopupWindowController(
      delegate: _PopupDelegate(),
      constraints: const BoxConstraints(minWidth: 200, minHeight: 100),
      anchorRect: const Rect.fromLTWH(10, 20, 30, 40),
      positioner: const WindowPositioner(
        parentAnchor: WindowPositionerAnchor.bottom,
        childAnchor: WindowPositionerAnchor.top,
        offset: Offset(1, 2),
        constraintAdjustment: WindowPositionerConstraintAdjustment(
          slideX: true,
          flipY: true,
        ),
      ),
      parent: regular,
    );

    expect(popup.parent, same(regular));

    final request = backend.requests.last;
    expect(request.kind, FiloWindowKind.popup);
    expect(request.parentViewId, regularId);
    expect(request.decorated, isFalse);
    expect(request.resizable, isFalse);

    final positioner = request.positioner!;
    expect(positioner.size.width, 200);
    expect(positioner.size.height, 100);
    expect(positioner.anchorRect.x, 10);
    expect(positioner.anchorRect.y, 20);
    expect(positioner.anchorRect.width, 30);
    expect(positioner.anchorRect.height, 40);
    expect(positioner.anchor, FiloPositionerAnchor.bottom);
    expect(positioner.gravity, FiloPositionerGravity.top);
    expect(positioner.offset!.x, 1);
    expect(positioner.offset!.y, 2);
    expect(positioner.constrainsAdjustments!.value, 1 | 8);
  });

  test('satellites are unsupported', () {
    final regular = owner.createRegularWindowController(
      delegate: _RegularDelegate(),
      size: const Size(100, 100),
      resizable: true,
    );

    expect(
      () => owner.createSatelliteWindowController(
        delegate: _SatelliteDelegate(),
        parent: regular,
        initialPositioner: const WindowPositioner(),
        resizable: true,
      ),
      throwsUnimplementedError,
    );
  });
}

class _RegularDelegate with RegularWindowControllerDelegate {
  int closeRequests = 0;
  int destroyed = 0;

  @override
  void onWindowCloseRequested(RegularWindowController controller) {
    closeRequests++;
  }

  @override
  void onWindowDestroyed() {
    destroyed++;
  }
}

class _DialogDelegate with DialogWindowControllerDelegate {
  @override
  void onWindowDestroyed() {}
}

class _PopupDelegate with PopupWindowControllerDelegate {
  @override
  void onWindowDestroyed() {}
}

class _SatelliteDelegate with SatelliteWindowControllerDelegate {
  @override
  void onWindowCloseRequested(SatelliteWindowController controller) {}

  @override
  void onWindowDestroyed() {}
}
