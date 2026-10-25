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
    owner = installFiloWindowing(backend: backend, viewResolver: (_) => view);
  });

  test(
    'a regular window adopts the implicit view and forwards its request',
    () {
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
      expect(backend.observers.keys, contains(0));

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
    },
  );

  test('close requests call the delegate directly', () {
    final delegate = _RegularDelegate();
    owner.createRegularWindowController(
      delegate: delegate,
      size: const Size(100, 100),
      resizable: true,
    );
    final id = backend.lastViewId!;

    backend.observerFor(id).onClose?.call();

    expect(delegate.closeRequests, 1);
  });

  test('onDestroy calls the delegate and marks the controller destroyed', () {
    final delegate = _RegularDelegate();
    final controller = owner.createRegularWindowController(
      delegate: delegate,
      size: const Size(100, 100),
      resizable: true,
    );
    final id = backend.lastViewId!;
    var notified = 0;
    controller.addListener(() => notified++);

    backend.observerFor(id).onDestroy?.call();

    expect(delegate.destroyed, 1);
    expect(notified, 0);
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

  test('onStateChanged updates the state and notifies listeners', () {
    final delegate = _RegularDelegate();
    final controller = owner.createRegularWindowController(
      delegate: delegate,
      size: const Size(100, 100),
      resizable: true,
    );
    final id = backend.lastViewId!;
    var notified = 0;
    controller.addListener(() => notified++);

    backend
        .observerFor(id)
        .onStateChanged
        ?.call(FiloToplevelState.activated.mask);

    expect(notified, 1);
    expect(controller.isActivated, isTrue);
  });

  test('onConfigure updates the content size and notifies listeners', () {
    final delegate = _RegularDelegate();
    final controller = owner.createRegularWindowController(
      delegate: delegate,
      size: const Size(100, 100),
      resizable: true,
    );
    final id = backend.lastViewId!;
    var notified = 0;
    controller.addListener(() => notified++);

    backend.observerFor(id).onConfigure?.call(const Size(640, 480));

    expect(notified, 1);
    expect(controller.contentSize, const Size(640, 480));
  });

  test('onMoved updates a popup offset and notifies listeners', () {
    final regular = owner.createRegularWindowController(
      delegate: _RegularDelegate(),
      size: const Size(100, 100),
      resizable: true,
    );
    final popup = owner.createPopupWindowController(
      delegate: _PopupDelegate(),
      constraints: const BoxConstraints(minWidth: 200, minHeight: 100),
      anchorRect: const Rect.fromLTWH(10, 20, 30, 40),
      positioner: const WindowPositioner(),
      parent: regular,
    );
    final id = backend.lastViewId!;
    var notified = 0;
    popup.addListener(() => notified++);

    backend.observerFor(id).onMoved?.call(const Offset(12, -8));

    expect(notified, 1);
    expect(popup.offsetFromParent, const Offset(12, -8));
  });

  test('onTitleChanged updates the title and notifies listeners', () {
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

    backend.observerFor(id).onTitleChanged?.call('native');

    expect(notified, 1);
    expect(controller.title, 'native');
  });

  test('setTitle updates the backend and the cached title', () {
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

    expect(backend.calls, contains('setTitle:$id:after'));
    expect(controller.title, 'after');
    expect(notified, 1);
  });

  test(
    'a layer window carries its layer surface and does not adopt view 0',
    () {
      final delegate = _RegularDelegate();
      final controller = owner.createLayerWindowController(
        delegate: delegate,
        layerSurface: FiloLayerSurface(
          layer: FiloLayer.overlay,
          anchors:
              FiloLayerAnchors.top |
              FiloLayerAnchors.left |
              FiloLayerAnchors.right,
          exclusiveZone: 32,
          keyboardInteractivity: FiloLayerKeyboardInteractivity.onDemand,
          margin: FiloInsets(top: 4, left: 8, right: 8),
          output: 0,
          namespace: 'filo-test',
          acceptsInput: false,
        ),
        size: const Size(0, 32),
      );

      expect(controller.rootView, same(view));
      expect(backend.lastViewId, isNot(0));
      expect(controller.layerSurface.layer, FiloLayer.overlay);

      final request = backend.requests.single;
      expect(request.kind, FiloWindowKind.layer);
      expect(request.preferredViewId, -1);
      expect(request.resizable, isFalse);
      expect(request.sizedToContent, isFalse);

      final layer = request.layer!;
      expect(layer.anchors.value, 1 | 4 | 8);
      expect(layer.anchors.isTop, isTrue);
      expect(layer.anchors.isBottom, isFalse);
      expect(layer.exclusiveZone, 32);
      expect(
        layer.keyboardInteractivity,
        FiloLayerKeyboardInteractivity.onDemand,
      );
      expect(layer.margin.top, 4);
      expect(layer.margin.left, 8);
      expect(layer.output, 0);
      expect(layer.namespace, 'filo-test');
      expect(layer.acceptsInput, isFalse);
    },
  );

  test('updating layer properties goes through the backend', () {
    final controller = owner.createLayerWindowController(
      delegate: _RegularDelegate(),
      layerSurface: const FiloLayerSurface(),
    );
    final id = backend.lastViewId!;

    controller.setAnchors(FiloLayerAnchors.bottom);
    controller.setExclusiveZone(-1);
    controller.setMargins(const FiloInsets.all(6));
    controller.setKeyboardInteractivity(
      FiloLayerKeyboardInteractivity.exclusive,
    );
    controller.setAcceptsInput(false);
    controller.setLayer(FiloLayer.bottom);

    expect(controller.layerSurface.layer, FiloLayer.bottom);
    expect(controller.layerSurface.anchors.value, 2);
    expect(controller.layerSurface.exclusiveZone, -1);
    expect(controller.layerSurface.margin.bottom, 6);
    expect(
      controller.layerSurface.keyboardInteractivity,
      FiloLayerKeyboardInteractivity.exclusive,
    );
    expect(controller.layerSurface.acceptsInput, isFalse);
    expect(backend.calls, contains('updateLayerSurface:$id:bottom'));
    expect(
      backend.calls.where((call) => call == 'updateLayerSurface:$id:bottom'),
      hasLength(1),
    );
    expect(
      backend.calls.where((call) => call == 'updateLayerSurface:$id:top'),
      hasLength(5),
    );
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

  testWidgets('FiloLayerWindow renders the controller root view', (
    tester,
  ) async {
    final controller = owner.createLayerWindowController(
      delegate: _RegularDelegate(),
      layerSurface: const FiloLayerSurface(),
      size: const Size(200, 100),
    );

    await tester.pumpWidget(
      FiloLayerWindow(
        controller: controller,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('layer content'),
        ),
      ),
      wrapWithView: false,
    );

    expect(find.text('layer content'), findsOneWidget);
    expect(
      WindowScope.of(tester.element(find.text('layer content'))),
      same(controller),
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
