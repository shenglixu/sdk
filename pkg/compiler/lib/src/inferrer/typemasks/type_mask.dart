// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of masks;

/// An implementation of a [UniverseSelectorConstraints] that is consists if an
/// only increasing set of [TypeMask]s, that is, once a mask is added it cannot
/// be removed.
class IncreasingTypeMaskSet extends UniverseSelectorConstraints {
  bool isAll = false;
  Set<TypeMask> _masks;

  @override
  bool applies(MemberEntity element, Selector selector, JClosedWorld world) {
    if (isAll) return true;
    if (_masks == null) return false;
    for (TypeMask mask in _masks) {
      if (mask.canHit(element, selector, world)) return true;
    }
    return false;
  }

  @override
  bool needsNoSuchMethodHandling(Selector selector, JClosedWorld world) {
    if (isAll) {
      TypeMask mask =
          new TypeMask.subclass(world.commonElements.objectClass, world);
      return mask.needsNoSuchMethodHandling(selector, world);
    }
    for (TypeMask mask in _masks) {
      if (mask.needsNoSuchMethodHandling(selector, world)) {
        return true;
      }
    }
    return false;
  }

  @override
  bool addReceiverConstraint(TypeMask mask) {
    if (isAll) return false;
    if (mask == null) {
      isAll = true;
      _masks = null;
      return true;
    }
    _masks ??= new Set<TypeMask>();
    return _masks.add(mask);
  }

  String toString() {
    if (isAll) {
      return '<all>';
    } else if (_masks != null) {
      return '$_masks';
    } else {
      return '<none>';
    }
  }
}

class TypeMaskStrategy implements AbstractValueStrategy {
  const TypeMaskStrategy();

  @override
  AbstractValueDomain createDomain(JClosedWorld closedWorld) {
    return new CommonMasks(closedWorld);
  }

  @override
  SelectorConstraintsStrategy createSelectorStrategy() {
    return new TypeMaskSelectorStrategy();
  }
}

class TypeMaskSelectorStrategy implements SelectorConstraintsStrategy {
  const TypeMaskSelectorStrategy();

  @override
  UniverseSelectorConstraints createSelectorConstraints(Selector selector) {
    return new IncreasingTypeMaskSet();
  }

  @override
  bool appliedUnnamed(DynamicUse dynamicUse, MemberEntity member,
      covariant JClosedWorld world) {
    Selector selector = dynamicUse.selector;
    TypeMask mask = dynamicUse.receiverConstraint;
    return selector.appliesUnnamed(member) &&
        (mask == null || mask.canHit(member, selector, world));
  }
}

/**
 * A type mask represents a set of contained classes, but the
 * operations on it are not guaranteed to be precise and they may
 * yield conservative answers that contain too many classes.
 */
abstract class TypeMask implements AbstractValue {
  factory TypeMask(
      ClassEntity base, int kind, bool isNullable, JClosedWorld closedWorld) {
    return new FlatTypeMask.normalized(
        base, (kind << 1) | (isNullable ? 1 : 0), closedWorld);
  }

  const factory TypeMask.empty() = FlatTypeMask.empty;

  factory TypeMask.exact(ClassEntity base, JClosedWorld closedWorld) {
    assert(
        closedWorld.classHierarchy.isInstantiated(base),
        failedAt(
            base ?? CURRENT_ELEMENT_SPANNABLE,
            "Cannot create exact type mask for uninstantiated "
            "class $base.\n${closedWorld.classHierarchy.dump(base)}"));
    return new FlatTypeMask.exact(base);
  }

  factory TypeMask.exactOrEmpty(ClassEntity base, JClosedWorld closedWorld) {
    if (closedWorld.classHierarchy.isInstantiated(base))
      return new FlatTypeMask.exact(base);
    return const TypeMask.empty();
  }

  factory TypeMask.subclass(ClassEntity base, JClosedWorld closedWorld) {
    assert(
        closedWorld.classHierarchy.isInstantiated(base),
        failedAt(
            base ?? CURRENT_ELEMENT_SPANNABLE,
            "Cannot create subclass type mask for uninstantiated "
            "class $base.\n${closedWorld.classHierarchy.dump(base)}"));
    ClassEntity topmost = closedWorld.getLubOfInstantiatedSubclasses(base);
    if (topmost == null) {
      return new TypeMask.empty();
    } else if (closedWorld.classHierarchy.hasAnyStrictSubclass(topmost)) {
      return new FlatTypeMask.subclass(topmost);
    } else {
      return new TypeMask.exact(topmost, closedWorld);
    }
  }

  factory TypeMask.subtype(ClassEntity base, JClosedWorld closedWorld) {
    ClassEntity topmost = closedWorld.getLubOfInstantiatedSubtypes(base);
    if (topmost == null) {
      return new TypeMask.empty();
    }
    if (closedWorld.classHierarchy.hasOnlySubclasses(topmost)) {
      return new TypeMask.subclass(topmost, closedWorld);
    }
    if (closedWorld.classHierarchy.hasAnyStrictSubtype(topmost)) {
      return new FlatTypeMask.subtype(topmost);
    } else {
      return new TypeMask.exact(topmost, closedWorld);
    }
  }

  const factory TypeMask.nonNullEmpty() = FlatTypeMask.nonNullEmpty;

  factory TypeMask.nonNullExact(ClassEntity base, JClosedWorld closedWorld) {
    assert(
        closedWorld.classHierarchy.isInstantiated(base),
        failedAt(
            base ?? CURRENT_ELEMENT_SPANNABLE,
            "Cannot create exact type mask for uninstantiated "
            "class $base.\n${closedWorld.classHierarchy.dump(base)}"));
    return new FlatTypeMask.nonNullExact(base);
  }

  factory TypeMask.nonNullExactOrEmpty(
      ClassEntity base, JClosedWorld closedWorld) {
    if (closedWorld.classHierarchy.isInstantiated(base)) {
      return new FlatTypeMask.nonNullExact(base);
    }
    return const TypeMask.nonNullEmpty();
  }

  factory TypeMask.nonNullSubclass(ClassEntity base, JClosedWorld closedWorld) {
    assert(
        closedWorld.classHierarchy.isInstantiated(base),
        failedAt(
            base ?? CURRENT_ELEMENT_SPANNABLE,
            "Cannot create subclass type mask for uninstantiated "
            "class $base.\n${closedWorld.classHierarchy.dump(base)}"));
    ClassEntity topmost = closedWorld.getLubOfInstantiatedSubclasses(base);
    if (topmost == null) {
      return new TypeMask.nonNullEmpty();
    } else if (closedWorld.classHierarchy.hasAnyStrictSubclass(topmost)) {
      return new FlatTypeMask.nonNullSubclass(topmost);
    } else {
      return new TypeMask.nonNullExact(topmost, closedWorld);
    }
  }

  factory TypeMask.nonNullSubtype(ClassEntity base, JClosedWorld closedWorld) {
    ClassEntity topmost = closedWorld.getLubOfInstantiatedSubtypes(base);
    if (topmost == null) {
      return new TypeMask.nonNullEmpty();
    }
    if (closedWorld.classHierarchy.hasOnlySubclasses(topmost)) {
      return new TypeMask.nonNullSubclass(topmost, closedWorld);
    }
    if (closedWorld.classHierarchy.hasAnyStrictSubtype(topmost)) {
      return new FlatTypeMask.nonNullSubtype(topmost);
    } else {
      return new TypeMask.nonNullExact(topmost, closedWorld);
    }
  }

  factory TypeMask.unionOf(Iterable<TypeMask> masks, JClosedWorld closedWorld) {
    return UnionTypeMask.unionOf(masks, closedWorld);
  }

  /**
   * If [mask] is forwarding, returns the first non-forwarding [TypeMask] in
   * [mask]'s forwarding chain.
   */
  static TypeMask nonForwardingMask(mask) {
    while (mask.isForwarding) {
      mask = mask.forwardTo;
    }
    return mask;
  }

  /**
   * Asserts that this mask uses the smallest possible representation for
   * its types. Currently, we normalize subtype and subclass to exact if no
   * subtypes or subclasses are present and subtype to subclass if only
   * subclasses exist. We also normalize exact to empty if the corresponding
   * baseclass was never instantiated.
   */
  static bool assertIsNormalized(TypeMask mask, JClosedWorld closedWorld) {
    String reason = getNotNormalizedReason(mask, closedWorld);
    assert(reason == null,
        failedAt(NO_LOCATION_SPANNABLE, '$mask is not normalized: $reason'));
    return true;
  }

  static String getNotNormalizedReason(
      TypeMask mask, JClosedWorld closedWorld) {
    mask = nonForwardingMask(mask);
    if (mask is FlatTypeMask) {
      if (mask.isEmptyOrNull) return null;
      if (mask.isExact) {
        if (!closedWorld.classHierarchy.isInstantiated(mask.base)) {
          return 'Exact ${mask.base} is not instantiated.';
        }
        return null;
      }
      if (mask.isSubclass) {
        if (!closedWorld.classHierarchy.hasAnyStrictSubclass(mask.base)) {
          return 'Subclass ${mask.base} does not have any subclasses.';
        }
        return null;
      }
      assert(mask.isSubtype);
      if (!closedWorld.classHierarchy.hasAnyStrictSubtype(mask.base)) {
        return 'Subtype ${mask.base} does not have any subclasses.';
      }
      if (closedWorld.classHierarchy.hasOnlySubclasses(mask.base)) {
        return 'Subtype ${mask.base} only has subclasses.';
      }
      return null;
    } else if (mask is UnionTypeMask) {
      for (TypeMask submask in mask.disjointMasks) {
        String submaskReason = getNotNormalizedReason(submask, closedWorld);
        if (submaskReason != null) {
          return 'Submask $submask in $mask: $submaskReason.';
        }
      }
      return null;
    }
    return 'Unknown type mask $mask.';
  }

  /**
   * Returns a nullable variant of [this] type mask.
   */
  TypeMask nullable();

  /**
   * Returns a non-nullable variant of [this] type mask.
   */
  TypeMask nonNullable();

  /// Whether nothing matches this mask, not even null.
  bool get isEmpty;

  /// Whether null is a valid value of this mask.
  bool get isNullable;

  /// Whether the only possible value in this mask is Null.
  bool get isNull;

  /// Whether [isEmpty] or [isNull] is true.
  bool get isEmptyOrNull;

  /// Whether this mask only includes instances of an exact class, and none of
  /// it's subclasses or subtypes.
  bool get isExact;

  /// Returns true if this mask is a union type.
  bool get isUnion;

  /// Returns `true` if this mask is a [ContainerTypeMask].
  bool get isContainer;

  /// Returns `true` if this mask is a [MapTypeMask].
  bool get isMap;

  /// Returns `true` if this mask is a [MapTypeMask] in dictionary mode, i.e.,
  /// all keys are known string values and we have specific type information for
  /// corresponding values.
  bool get isDictionary;

  /// Returns `true` if this mask is wrapping another mask for the purpose of
  /// tracing.
  bool get isForwarding;

  /// Returns `true` if this mask holds encodes an exact value within a type.
  bool get isValue;

  bool containsOnlyInt(JClosedWorld closedWorld);
  bool containsOnlyDouble(JClosedWorld closedWorld);
  bool containsOnlyNum(JClosedWorld closedWorld);
  bool containsOnlyBool(JClosedWorld closedWorld);
  bool containsOnlyString(JClosedWorld closedWorld);
  bool containsOnly(ClassEntity cls);

  /**
   * Compares two [TypeMask] objects for structural equality.
   *
   * Note: This may differ from semantic equality in the set containment sense.
   *   Use [containsMask] and [isInMask] for that, instead.
   */
  bool operator ==(other);

  /**
   * If this returns `true`, [other] is guaranteed to be a supertype of this
   * mask, i.e., this mask is in [other]. However, the inverse does not hold.
   * Enable [UnionTypeMask.PERFORM_EXTRA_CONTAINS_CHECK] to be notified of
   * false negatives.
   */
  bool isInMask(TypeMask other, JClosedWorld closedWorld);

  /**
   * If this returns `true`, [other] is guaranteed to be a subtype of this mask,
   * i.e., this mask contains [other]. However, the inverse does not hold.
   * Enable [UnionTypeMask.PERFORM_EXTRA_CONTAINS_CHECK] to be notified of
   * false negatives.
   */
  bool containsMask(TypeMask other, JClosedWorld closedWorld);

  /**
   * Returns whether this type mask is an instance of [cls].
   */
  bool satisfies(ClassEntity cls, JClosedWorld closedWorld);

  /**
   * Returns whether or not this type mask contains the given class [cls].
   */
  bool contains(ClassEntity cls, JClosedWorld closedWorld);

  /// Returns whether or not this type mask contains all types.
  bool containsAll(JClosedWorld closedWorld);

  /// Returns the [ClassEntity] if this type represents a single class,
  /// otherwise returns `null`.  This method is conservative.
  ClassEntity singleClass(JClosedWorld closedWorld);

  /**
   * Returns a type mask representing the union of [this] and [other].
   */
  TypeMask union(TypeMask other, JClosedWorld closedWorld);

  /// Returns whether the intersection of this and [other] is empty.
  bool isDisjoint(TypeMask other, JClosedWorld closedWorld);

  /**
   * Returns a type mask representing the intersection of [this] and [other].
   */
  TypeMask intersection(TypeMask other, JClosedWorld closedWorld);

  /**
   * Returns whether [element] is a potential target when being
   * invoked on this type mask. [selector] is used to ensure library
   * privacy is taken into account.
   */
  bool canHit(
      MemberEntity element, Selector selector, JClosedWorld closedWorld);

  /// Returns whether this [TypeMask] applied to [selector] can hit a
  /// [noSuchMethod].
  bool needsNoSuchMethodHandling(Selector selector, JClosedWorld world);

  /**
   * Returns the [element] that is known to always be hit at runtime
   * on this mask. Returns null if there is none.
   */
  MemberEntity locateSingleMember(Selector selector, JClosedWorld closedWorld);
}
