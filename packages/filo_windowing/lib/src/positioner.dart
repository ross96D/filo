import 'models.dart';

class FiloPositioner {
  /// Set the size of the surface that is to be positioned with the positioner object.
  /// The size is in surface-local coordinates and corresponds to the window geometry.
  ///
  /// If a zero or negative size is set the invalid_input error is raised.
  FiloSize size;

  /// Specify the anchor rectangle within the parent surface that
  /// the child surface will be placed relative to.
  /// The rectangle is relative to the window geometry as defined
  /// by xdg_surface.set_window_geometry of the parent surface.
  ///
  /// When the xdg_positioner object is used to position a child surface,
  /// the anchor rectangle may not extend outside the window geometry
  /// of the positioned child's parent surface.
  ///
  /// If a negative size is set the invalid_input error is raised.
  FiloRect anchorRect;

  /// Defines the anchor point for the anchor rectangle.
  /// The specified anchor is used to derive an anchor point
  /// that the child surface will be positioned relative to.
  /// If a corner anchor is set (e.g. 'top_left' or 'bottom_right'),
  /// the anchor point will be at the specified corner; otherwise,
  /// the derived anchor point will be centered on the specified edge,
  /// or in the center of the anchor rectangle if no edge is specified.
  FiloPositionerAnchor? anchor;

  /// Defines in what direction a surface should be positioned,
  /// relative to the anchor point of the parent surface.
  /// If a corner gravity is specified (e.g. 'bottom_right' or 'top_left'),
  /// then the child surface will be placed towards the specified gravity;
  /// otherwise, the child surface will be centered over the anchor point
  /// on any axis that had no gravity specified. If the gravity is not in
  /// the ‘gravity’ enum, an invalid_input error is raised.
  FiloPositionerGravity? gravity;

  /// Specify how the window should be positioned if the originally intended
  /// position caused the surface to be constrained, meaning at least partially
  /// outside positioning boundaries set by the compositor.
  /// The adjustment is set by constructing a bitmask describing the adjustment to be
  /// made when the surface is constrained on that axis.
  ///
  /// If no bit for one axis is set, the compositor will assume that the child
  /// surface should not change its position on that axis when constrained.
  ///
  /// If more than one bit for one axis is set, the order of how adjustments are
  /// applied is specified in the corresponding adjustment descriptions.
  ///
  /// The default adjustment is none.
  FiloPositionerConstrainsAdjustmentsFlags? constrainsAdjustments;

  /// Specify the surface position offset relative to the position of the anchor
  /// on the anchor rectangle and the anchor on the surface.
  /// For example if the anchor of the anchor rectangle is at (x, y),
  /// the surface has the gravity bottom|right, and the offset is (ox, oy),
  /// the calculated surface position will be (x + ox, y + oy).
  /// The offset position of the surface is the one used for constraint testing.
  ///
  /// An example use case is placing a popup menu on top of a user interface element,
  /// while aligning the user interface element of the parent surface with some user
  /// interface element placed somewhere in the popup surface.
  FiloOffset? offset;

  FiloPositioner({
    required this.size,
    required this.anchorRect,
    this.anchor,
    this.constrainsAdjustments,
    this.gravity,
    this.offset,
  });

  /// Copy this positioner with some fields replaced.
  FiloPositioner copyWith({
    FiloSize? size,
    FiloRect? anchorRect,
    FiloPositionerAnchor? anchor,
    FiloPositionerGravity? gravity,
    FiloPositionerConstrainsAdjustmentsFlags? constrainsAdjustments,
    FiloOffset? offset,
  }) {
    return FiloPositioner(
      size: size ?? this.size,
      anchorRect: anchorRect ?? this.anchorRect,
      anchor: anchor ?? this.anchor,
      gravity: gravity ?? this.gravity,
      constrainsAdjustments: constrainsAdjustments ?? this.constrainsAdjustments,
      offset: offset ?? this.offset,
    );
  }
}
