// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:core';

import 'package:analysis_server/plugin/edit/fix/fix_core.dart';
import 'package:analysis_server/plugin/edit/fix/fix_dart.dart';
import 'package:analysis_server/src/services/completion/dart/utilities.dart';
import 'package:analysis_server/src/services/correction/fix.dart';
import 'package:analysis_server/src/services/correction/levenshtein.dart';
import 'package:analysis_server/src/services/correction/namespace.dart';
import 'package:analysis_server/src/services/correction/strings.dart';
import 'package:analysis_server/src/services/correction/util.dart';
import 'package:analysis_server/src/services/search/hierarchy.dart';
import 'package:analysis_server/src/utilities/flutter.dart' as flutter;
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/standard_resolution_map.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/exception/exception.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/src/context/context_root.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/dart/analysis/session_helper.dart';
import 'package:analyzer/src/dart/analysis/top_level_declaration.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/ast/token.dart';
import 'package:analyzer/src/dart/ast/utilities.dart';
import 'package:analyzer/src/dart/element/ast_provider.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/member.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/error/inheritance_override.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/error_verifier.dart';
import 'package:analyzer/src/generated/java_core.dart';
import 'package:analyzer/src/generated/parser.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart'
    hide AnalysisError, Element, ElementKind;
import 'package:analyzer_plugin/src/utilities/string_utilities.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_dart.dart';
import 'package:analyzer_plugin/utilities/fixes/fixes.dart' hide FixContributor;
import 'package:analyzer_plugin/utilities/range_factory.dart';
import 'package:path/path.dart';

/**
 * A predicate is a one-argument function that returns a boolean value.
 */
typedef bool ElementPredicate(Element argument);

/**
 * The implementation of [DartFixContext].
 *
 * Clients may not extend, implement or mix-in this class.
 */
class DartFixContextImpl extends FixContextImpl implements DartFixContext {
  @override
  final AstProvider astProvider;

  @override
  final CompilationUnit unit;

  DartFixContextImpl(FixContext fixContext, this.astProvider, this.unit)
      : super.from(fixContext);

  GetTopLevelDeclarations get getTopLevelDeclarations =>
      analysisDriver.getTopLevelNameDeclarations;
}

/**
 * A [FixContributor] that provides the default set of fixes.
 */
class DefaultFixContributor extends DartFixContributor {
  @override
  Future<List<Fix>> internalComputeFixes(DartFixContext context) async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    try {
      FixProcessor processor = new FixProcessor(context);
      List<Fix> fixes = await processor.compute();
      List<Fix> fixAllFixes = await _computeFixAllFixes(context, fixes);
      return new List.from(fixes)..addAll(fixAllFixes);
    } on CancelCorrectionException {
      return const <Fix>[];
    }
  }

  Future<List<Fix>> _computeFixAllFixes(
      DartFixContext context, List<Fix> fixes) async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    final AnalysisError analysisError = context.error;
    final List<AnalysisError> allAnalysisErrors = context.errors;

    // Validate inputs:
    // - return if no fixes
    // - return if no other analysis errors
    if (fixes.isEmpty || allAnalysisErrors.length < 2) {
      return const <Fix>[];
    }

    // Remove any analysis errors that don't have the expected error code name
    allAnalysisErrors
        .removeWhere((e) => analysisError.errorCode.name != e.errorCode.name);
    if (allAnalysisErrors.length < 2) {
      return const <Fix>[];
    }

    // A map between each FixKind and the List of associated fixes
    final HashMap<FixKind, List<Fix>> map = new HashMap();

    // Populate the HashMap by looping through all AnalysisErrors, creating a
    // new FixProcessor to compute the other fixes that can be applied with this
    // one.
    // For each fix, put the fix into the HashMap.
    for (int i = 0; i < allAnalysisErrors.length; i++) {
      final FixContext fixContextI = new FixContextImpl(
          context.resourceProvider,
          context.analysisDriver,
          allAnalysisErrors[i],
          allAnalysisErrors);
      final DartFixContextImpl dartFixContextI = new DartFixContextImpl(
          fixContextI, context.astProvider, context.unit);
      final FixProcessor processorI = new FixProcessor(dartFixContextI);
      final List<Fix> fixesListI = await processorI.compute();
      for (Fix f in fixesListI) {
        if (!map.containsKey(f.kind)) {
          map[f.kind] = new List<Fix>()..add(f);
        } else {
          map[f.kind].add(f);
        }
      }
    }

    // For each FixKind in the HashMap, union each list together, then return
    // the set of unioned Fixes.
    final List<Fix> result = new List<Fix>();
    map.forEach((FixKind kind, List<Fix> fixesListJ) {
      if (fixesListJ.first.kind.canBeAppliedTogether()) {
        Fix unionFix = _unionFixList(fixesListJ);
        if (unionFix != null) {
          result.add(unionFix);
        }
      }
    });
    return result;
  }

  Fix _unionFixList(List<Fix> fixList) {
    if (fixList == null || fixList.isEmpty) {
      return null;
    } else if (fixList.length == 1) {
      return fixList[0];
    }
    final SourceChange sourceChange =
        new SourceChange(fixList[0].kind.appliedTogetherMessage);
    sourceChange.edits = new List.from(fixList[0].change.edits);
    final List<SourceEdit> edits = new List<SourceEdit>();
    edits.addAll(fixList[0].change.edits[0].edits);
    sourceChange.linkedEditGroups =
        new List.from(fixList[0].change.linkedEditGroups);
    for (int i = 1; i < fixList.length; i++) {
      edits.addAll(fixList[i].change.edits[0].edits);
      sourceChange.linkedEditGroups..addAll(fixList[i].change.linkedEditGroups);
    }
    // Sort the list of SourceEdits so that when the edits are applied, they
    // are applied from the end of the file to the top of the file.
    edits.sort((s1, s2) => s2.offset - s1.offset);

    sourceChange.edits[0].edits = edits;

    return new Fix(fixList[0].kind, sourceChange);
  }
}

/**
 * The computer for Dart fixes.
 */
class FixProcessor {
  static const int MAX_LEVENSHTEIN_DISTANCE = 3;

  ResourceProvider resourceProvider;
  AstProvider astProvider;
  GetTopLevelDeclarations getTopLevelDeclarations;
  CompilationUnit unit;
  AnalysisError error;

  /**
   * The analysis driver being used to perform analysis.
   */
  AnalysisDriver driver;

  /**
   * The analysis session to be used to create the change builder.
   */
  AnalysisSession session;

  /**
   * The helper wrapper around the [session].
   */
  AnalysisSessionHelper sessionHelper;

  String file;
  CompilationUnitElement unitElement;
  Source unitSource;
  LibraryElement unitLibraryElement;
  File unitLibraryFile;
  Folder unitLibraryFolder;

  final List<Fix> fixes = <Fix>[];

  CorrectionUtils utils;
  int errorOffset;
  int errorLength;
  int errorEnd;
  SourceRange errorRange;
  AstNode node;
  AstNode coveredNode;

  TypeProvider _typeProvider;
  TypeSystem _typeSystem;

  FixProcessor(DartFixContext dartContext) {
    resourceProvider = dartContext.resourceProvider;
    astProvider = dartContext.astProvider;
    getTopLevelDeclarations = dartContext.getTopLevelDeclarations;

    driver = dartContext.analysisDriver;
    session = driver.currentSession;
    sessionHelper = new AnalysisSessionHelper(session);

    // unit
    unit = dartContext.unit;
    unitElement = unit.declaredElement;
    unitSource = unitElement.source;
    // file
    file = unitSource.fullName;
    // library
    unitLibraryElement = unitElement.library;
    String unitLibraryPath = unitLibraryElement.source.fullName;
    unitLibraryFile = resourceProvider.getFile(unitLibraryPath);
    unitLibraryFolder = unitLibraryFile.parent;
    // error
    error = dartContext.error;
  }

  DartType get coreTypeBool => _getCoreType('bool');

  /**
   * Returns the EOL to use for this [CompilationUnit].
   */
  String get eol => utils.endOfLine;

  TypeProvider get typeProvider {
    if (_typeProvider == null) {
      _typeProvider = unitElement.context.typeProvider;
    }
    return _typeProvider;
  }

  TypeSystem get typeSystem {
    if (_typeSystem == null) {
      _typeSystem = new StrongTypeSystemImpl(typeProvider);
    }
    return _typeSystem;
  }

  Future<List<Fix>> compute() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    try {
      utils = new CorrectionUtils(unit);
    } catch (e) {
      throw new CancelCorrectionException(exception: e);
    }

    errorOffset = error.offset;
    errorLength = error.length;
    errorEnd = errorOffset + errorLength;
    errorRange = new SourceRange(errorOffset, errorLength);
    node = new NodeLocator2(errorOffset).searchWithin(unit);
    coveredNode =
        new NodeLocator2(errorOffset, errorEnd - 1).searchWithin(unit);
    if (coveredNode == null) {
      // TODO(brianwilkerson) Figure out why the coveredNode is sometimes null.
      return fixes;
    }

    // analyze ErrorCode
    ErrorCode errorCode = error.errorCode;
    if (errorCode == StaticWarningCode.UNDEFINED_CLASS_BOOLEAN) {
      await _addFix_boolInsteadOfBoolean();
    }
    if (errorCode ==
        CompileTimeErrorCode.CONST_INITIALIZED_WITH_NON_CONSTANT_VALUE) {
      await _addFix_replaceWithConstInstanceCreation();
    }
    if (errorCode == CompileTimeErrorCode.ASYNC_FOR_IN_WRONG_CONTEXT ||
        errorCode == StaticWarningCode.UNDEFINED_IDENTIFIER_AWAIT) {
      await _addFix_addAsync();
    }
    if ((errorCode == CompileTimeErrorCode.BUILT_IN_IDENTIFIER_AS_TYPE ||
            errorCode == ParserErrorCode.UNEXPECTED_TOKEN) &&
        error.message.indexOf("'await'") >= 0) {
      await _addFix_addAsync();
    }
    if (errorCode == CompileTimeErrorCode.INTEGER_LITERAL_IMPRECISE_AS_DOUBLE) {
      await _addFix_changeToNearestPreciseValue();
    }

    if (errorCode == CompileTimeErrorCode.INVALID_ANNOTATION ||
        errorCode == CompileTimeErrorCode.UNDEFINED_ANNOTATION) {
      if (node is Annotation) {
        Annotation annotation = node;
        Identifier name = annotation.name;
        if (name != null && name.staticElement == null) {
          node = name;
          if (annotation.arguments == null) {
            await _addFix_importLibrary_withTopLevelVariable();
          } else {
            await _addFix_importLibrary_withType();
            await _addFix_createClass();
            await _addFix_undefinedClass_useSimilar();
          }
        }
      }
    }
    if (errorCode ==
        CompileTimeErrorCode.NO_DEFAULT_SUPER_CONSTRUCTOR_EXPLICIT) {
      await _addFix_createConstructorSuperExplicit();
    }
    if (errorCode ==
        CompileTimeErrorCode.NO_DEFAULT_SUPER_CONSTRUCTOR_IMPLICIT) {
      await _addFix_createConstructorSuperImplicit();
      // TODO(brianwilkerson) The following was added because fasta produces
      // NO_DEFAULT_SUPER_CONSTRUCTOR_IMPLICIT in places where analyzer produced
      // NO_DEFAULT_SUPER_CONSTRUCTOR_EXPLICIT
      await _addFix_createConstructorSuperExplicit();
    }
    if (errorCode ==
        CompileTimeErrorCode.UNDEFINED_CONSTRUCTOR_IN_INITIALIZER_DEFAULT) {
      await _addFix_createConstructorSuperExplicit();
    }
    if (errorCode == CompileTimeErrorCode.URI_DOES_NOT_EXIST) {
      await _addFix_createImportUri();
      await _addFix_createPartUri();
    }
    if (errorCode == HintCode.CAN_BE_NULL_AFTER_NULL_AWARE) {
      await _addFix_canBeNullAfterNullAware();
    }
    if (errorCode == HintCode.DEAD_CODE) {
      await _addFix_removeDeadCode();
    }
    if (errorCode == HintCode.DIVISION_OPTIMIZATION) {
      await _addFix_useEffectiveIntegerDivision();
    }
    if (errorCode == HintCode.TYPE_CHECK_IS_NOT_NULL) {
      await _addFix_isNotNull();
    }
    if (errorCode == HintCode.TYPE_CHECK_IS_NULL) {
      await _addFix_isNull();
    }
    if (errorCode == HintCode.UNDEFINED_GETTER) {
      await _addFix_undefinedClassAccessor_useSimilar();
      await _addFix_createField();
      await _addFix_createGetter();
    }
    if (errorCode == HintCode.UNDEFINED_SETTER) {
      await _addFix_undefinedClassAccessor_useSimilar();
      await _addFix_createField();
    }
    if (errorCode == HintCode.UNNECESSARY_CAST) {
      await _addFix_removeUnnecessaryCast();
    }
    if (errorCode == HintCode.UNUSED_CATCH_CLAUSE) {
      await _addFix_removeUnusedCatchClause();
    }
    if (errorCode == HintCode.UNUSED_CATCH_STACK) {
      await _addFix_removeUnusedCatchStack();
    }
    if (errorCode == HintCode.UNUSED_IMPORT) {
      await _addFix_removeUnusedImport();
    }
    if (errorCode == ParserErrorCode.EXPECTED_TOKEN) {
      await _addFix_insertSemicolon();
    }
    if (errorCode == ParserErrorCode.GETTER_WITH_PARAMETERS) {
      await _addFix_removeParameters_inGetterDeclaration();
    }
    if (errorCode == ParserErrorCode.VAR_AS_TYPE_NAME) {
      await _addFix_replaceVarWithDynamic();
    }
    if (errorCode == StaticWarningCode.ASSIGNMENT_TO_FINAL) {
      await _addFix_makeFieldNotFinal();
    }
    if (errorCode == StaticWarningCode.CONCRETE_CLASS_WITH_ABSTRACT_MEMBER) {
      await _addFix_makeEnclosingClassAbstract();
    }
    if (errorCode == CompileTimeErrorCode.EXTRA_POSITIONAL_ARGUMENTS ||
        errorCode == StaticWarningCode.EXTRA_POSITIONAL_ARGUMENTS ||
        errorCode ==
            CompileTimeErrorCode.EXTRA_POSITIONAL_ARGUMENTS_COULD_BE_NAMED ||
        errorCode ==
            StaticWarningCode.EXTRA_POSITIONAL_ARGUMENTS_COULD_BE_NAMED) {
      await _addFix_createConstructor_insteadOfSyntheticDefault();
      await _addFix_addMissingParameter();
    }
    if (errorCode == HintCode.MISSING_REQUIRED_PARAM ||
        errorCode == HintCode.MISSING_REQUIRED_PARAM_WITH_DETAILS) {
      await _addFix_addMissingRequiredArgument();
    }
    if (errorCode == StaticWarningCode.NEW_WITH_UNDEFINED_CONSTRUCTOR) {
      await _addFix_createConstructor_named();
    }
    if (errorCode == StaticWarningCode.CONCRETE_CLASS_WITH_ABSTRACT_MEMBER ||
        errorCode ==
            StaticWarningCode.NON_ABSTRACT_CLASS_INHERITS_ABSTRACT_MEMBER_ONE ||
        errorCode ==
            StaticWarningCode.NON_ABSTRACT_CLASS_INHERITS_ABSTRACT_MEMBER_TWO ||
        errorCode ==
            StaticWarningCode
                .NON_ABSTRACT_CLASS_INHERITS_ABSTRACT_MEMBER_THREE ||
        errorCode ==
            StaticWarningCode
                .NON_ABSTRACT_CLASS_INHERITS_ABSTRACT_MEMBER_FOUR ||
        errorCode ==
            StaticWarningCode
                .NON_ABSTRACT_CLASS_INHERITS_ABSTRACT_MEMBER_FIVE_PLUS) {
      // make class abstract
      await _addFix_makeEnclosingClassAbstract();
      await _addFix_createNoSuchMethod();
      // implement methods
      await _addFix_createMissingOverrides();
    }
    if (errorCode == CompileTimeErrorCode.UNDEFINED_CLASS ||
        errorCode == StaticWarningCode.CAST_TO_NON_TYPE ||
        errorCode == StaticWarningCode.NOT_A_TYPE ||
        errorCode == StaticWarningCode.TYPE_TEST_WITH_UNDEFINED_NAME ||
        errorCode == StaticWarningCode.UNDEFINED_CLASS) {
      await _addFix_importLibrary_withType();
      await _addFix_createClass();
      await _addFix_createMixin();
      await _addFix_undefinedClass_useSimilar();
    }
    if (errorCode ==
            CompileTimeErrorCode.EXTRA_POSITIONAL_ARGUMENTS_COULD_BE_NAMED ||
        errorCode ==
            StaticWarningCode.EXTRA_POSITIONAL_ARGUMENTS_COULD_BE_NAMED) {
      await _addFix_convertToNamedArgument();
    }
    if (errorCode == StaticWarningCode.FINAL_NOT_INITIALIZED) {
      await _addFix_createConstructor_forUninitializedFinalFields();
    }
    if (errorCode == StaticWarningCode.FINAL_NOT_INITIALIZED_CONSTRUCTOR_1 ||
        errorCode == StaticWarningCode.FINAL_NOT_INITIALIZED_CONSTRUCTOR_2 ||
        errorCode ==
            StaticWarningCode.FINAL_NOT_INITIALIZED_CONSTRUCTOR_3_PLUS) {
      await _addFix_updateConstructor_forUninitializedFinalFields();
    }
    if (errorCode == StaticWarningCode.UNDEFINED_IDENTIFIER) {
      await _addFix_undefinedClassAccessor_useSimilar();
      await _addFix_createClass();
      await _addFix_createField();
      await _addFix_createGetter();
      await _addFix_createFunction_forFunctionType();
      await _addFix_createMixin();
      await _addFix_importLibrary_withType();
      await _addFix_importLibrary_withTopLevelVariable();
      await _addFix_createLocalVariable();
    }
    if (errorCode == CompileTimeErrorCode.UNDEFINED_NAMED_PARAMETER ||
        errorCode == StaticWarningCode.UNDEFINED_NAMED_PARAMETER) {
      await _addFix_addMissingNamedArgument();
    }
    if (errorCode == StaticTypeWarningCode.UNDEFINED_METHOD_WITH_CONSTRUCTOR) {
      await _addFix_undefinedMethodWithContructor();
    }
    if (errorCode == StaticTypeWarningCode.ILLEGAL_ASYNC_RETURN_TYPE) {
      await _addFix_illegalAsyncReturnType();
    }
    if (errorCode == StaticTypeWarningCode.INSTANCE_ACCESS_TO_STATIC_MEMBER) {
      await _addFix_useStaticAccess_method();
      await _addFix_useStaticAccess_property();
    }
    if (errorCode == StaticTypeWarningCode.INVALID_ASSIGNMENT) {
      await _addFix_addExplicitCast();
      await _addFix_changeTypeAnnotation();
    }
    if (errorCode == StaticTypeWarningCode.INVOCATION_OF_NON_FUNCTION) {
      await _addFix_removeParentheses_inGetterInvocation();
    }
    if (errorCode == StaticTypeWarningCode.NON_BOOL_CONDITION) {
      await _addFix_nonBoolCondition_addNotNull();
    }
    if (errorCode == StaticTypeWarningCode.NON_TYPE_AS_TYPE_ARGUMENT) {
      await _addFix_importLibrary_withType();
      await _addFix_createClass();
      await _addFix_createMixin();
    }
    if (errorCode == StaticTypeWarningCode.UNDEFINED_FUNCTION) {
      await _addFix_createClass();
      await _addFix_importLibrary_withFunction();
      await _addFix_importLibrary_withType();
      await _addFix_undefinedFunction_useSimilar();
      await _addFix_undefinedFunction_create();
    }
    if (errorCode == StaticTypeWarningCode.UNDEFINED_GETTER) {
      await _addFix_undefinedClassAccessor_useSimilar();
      await _addFix_createField();
      await _addFix_createGetter();
      await _addFix_createFunction_forFunctionType();
      // TODO(brianwilkerson) The following were added because fasta produces
      // UNDEFINED_GETTER in places where analyzer produced UNDEFINED_IDENTIFIER
      await _addFix_createClass();
      await _addFix_createMixin();
      await _addFix_createLocalVariable();
      await _addFix_importLibrary_withTopLevelVariable();
      await _addFix_importLibrary_withType();
    }
    if (errorCode == HintCode.UNDEFINED_METHOD ||
        errorCode == StaticTypeWarningCode.UNDEFINED_METHOD) {
      await _addFix_createClass();
      await _addFix_importLibrary_withFunction();
      await _addFix_importLibrary_withType();
      await _addFix_undefinedMethod_useSimilar();
      await _addFix_undefinedMethod_create();
      await _addFix_undefinedFunction_create();
    }
    if (errorCode == StaticTypeWarningCode.UNDEFINED_SETTER) {
      await _addFix_undefinedClassAccessor_useSimilar();
      await _addFix_createField();
    }
    if (errorCode == CompileTimeErrorCode.UNDEFINED_NAMED_PARAMETER ||
        errorCode == StaticWarningCode.UNDEFINED_NAMED_PARAMETER) {
      await _addFix_convertFlutterChild();
      await _addFix_convertFlutterChildren();
    }
    if (errorCode ==
        CompileTimeErrorCode.INITIALIZING_FORMAL_FOR_NON_EXISTENT_FIELD) {
      await _addFix_createField_initializingFormal();
    }
    if (errorCode == CompileTimeErrorCode.CONST_INSTANCE_FIELD) {
      await _addFix_addStatic();
    }
    if (errorCode ==
        StaticTypeWarningCode.WRONG_NUMBER_OF_TYPE_ARGUMENTS_CONSTRUCTOR) {
      await _addFix_moveTypeArgumentsToClass();
      await _addFix_removeTypeArguments();
    }
    // lints
    if (errorCode is LintCode) {
      String name = errorCode.name;
      if (name == LintNames.always_require_non_null_named_parameters) {
        await _addFix_addRequiredAnnotation();
      }
      if (name == LintNames.annotate_overrides) {
        await _addFix_addOverrideAnnotation();
      }
      if (name == LintNames.avoid_annotating_with_dynamic) {
        await _addFix_removeTypeAnnotation();
      }
      if (name == LintNames.avoid_empty_else) {
        await _addFix_removeEmptyElse();
      }
      if (name == LintNames.avoid_init_to_null) {
        await _addFix_removeInitializer();
      }
      if (name == LintNames.avoid_return_types_on_setters) {
        await _addFix_removeTypeAnnotation();
      }
      if (name == LintNames.avoid_types_on_closure_parameters) {
        await _addFix_replaceWithIdentifier();
      }
      if (name == LintNames.await_only_futures) {
        await _addFix_removeAwait();
      }
      if (name == LintNames.empty_catches) {
        await _addFix_removeEmptyCatch();
      }
      if (name == LintNames.empty_constructor_bodies) {
        await _addFix_removeEmptyConstructorBody();
      }
      if (name == LintNames.empty_statements) {
        await _addFix_removeEmptyStatement();
      }
      if (name == LintNames.non_constant_identifier_names) {
        await _addFix_renameToCamelCase();
      }
      if (name == LintNames.prefer_collection_literals) {
        await _addFix_replaceWithLiteral();
      }
      if (name == LintNames.prefer_conditional_assignment) {
        await _addFix_replaceWithConditionalAssignment();
      }
      if (errorCode.name == LintNames.prefer_const_declarations) {
        await _addFix_replaceFinalWithConst();
      }
      if (name == LintNames.prefer_final_fields) {
        await _addFix_makeVariableFinal();
      }
      if (name == LintNames.prefer_final_locals) {
        await _addFix_makeVariableFinal();
      }
      if (name == LintNames.prefer_is_not_empty) {
        await _addFix_isNotEmpty();
      }
      if (name == LintNames.type_init_formals) {
        await _addFix_removeTypeAnnotation();
      }
      if (name == LintNames.unnecessary_brace_in_string_interp) {
        await _addFix_removeInterpolationBraces();
      }
      if (name == LintNames.unnecessary_lambdas) {
        await _addFix_replaceWithTearOff();
      }
      if (name == LintNames.unnecessary_override) {
        await _addFix_removeMethodDeclaration();
      }
      if (name == LintNames.unnecessary_this) {
        await _addFix_removeThisExpression();
      }
    }
    // done
    return fixes;
  }

  Future<Fix> computeFix(ErrorCode errorCode) async {
    return null;
  }

  Future<void> _addFix_addAsync() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    FunctionBody body = node.getAncestor((n) => n is FunctionBody);
    if (body != null && body.keyword == null) {
      TypeProvider typeProvider = await this.typeProvider;
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.convertFunctionFromSyncToAsync(body, typeProvider);
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.ADD_ASYNC);
    }
  }

  Future<void> _addFix_addExplicitCast() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (coveredNode is! Expression) {
      return;
    }
    Expression target = coveredNode;
    DartType fromType = target.staticType;
    DartType toType;
    AstNode parent = target.parent;
    if (parent is AssignmentExpression && target == parent.rightHandSide) {
      toType = parent.leftHandSide.staticType;
    } else if (parent is VariableDeclaration && target == parent.initializer) {
      toType = parent.name.staticType;
    } else {
      // TODO(brianwilkerson) Handle function arguments.
      return;
    }
    // TODO(brianwilkerson) Handle `toSet` in a manner similar to the below.
    if (_isToListMethodInvocation(target)) {
      Expression targetTarget = (target as MethodInvocation).target;
      if (targetTarget != null) {
        DartType targetTargetType = targetTarget.staticType;
        if (_isDartCoreIterable(targetTargetType) ||
            _isDartCoreList(targetTargetType) ||
            _isDartCoreMap(targetTargetType) ||
            _isDartCoreSet(targetTargetType)) {
          target = targetTarget;
          fromType = targetTargetType;
        }
      }
    }
    if (target is AsExpression) {
      // TODO(brianwilkerson) Consider updating the right operand.
      return;
    }
    bool needsParentheses = target.precedence < 15;
    if (((_isDartCoreIterable(fromType) || _isDartCoreList(fromType)) &&
            _isDartCoreList(toType)) ||
        (_isDartCoreSet(fromType) && _isDartCoreSet(toType))) {
      if (_isCastMethodInvocation(target)) {
        // TODO(brianwilkerson) Consider updating the type arguments to the
        // `cast` invocation.
        return;
      }
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        if (needsParentheses) {
          builder.addSimpleInsertion(target.offset, '(');
        }
        builder.addInsertion(target.end, (DartEditBuilder builder) {
          if (needsParentheses) {
            builder.write(')');
          }
          builder.write('.cast<');
          builder.writeType((toType as InterfaceType).typeArguments[0]);
          builder.write('>()');
        });
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.ADD_EXPLICIT_CAST);
    } else if (_isDartCoreMap(fromType) && _isDartCoreMap(toType)) {
      if (_isCastMethodInvocation(target)) {
        // TODO(brianwilkerson) Consider updating the type arguments to the
        // `cast` invocation.
        return;
      }
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        if (needsParentheses) {
          builder.addSimpleInsertion(target.offset, '(');
        }
        builder.addInsertion(target.end, (DartEditBuilder builder) {
          if (needsParentheses) {
            builder.write(')');
          }
          builder.write('.cast<');
          builder.writeType((toType as InterfaceType).typeArguments[0]);
          builder.write(', ');
          builder.writeType((toType as InterfaceType).typeArguments[1]);
          builder.write('>()');
        });
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.ADD_EXPLICIT_CAST);
    } else {
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        if (needsParentheses) {
          builder.addSimpleInsertion(target.offset, '(');
        }
        builder.addInsertion(target.end, (DartEditBuilder builder) {
          if (needsParentheses) {
            builder.write(')');
          }
          builder.write(' as ');
          builder.writeType(toType);
        });
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.ADD_EXPLICIT_CAST);
    }
  }

  Future<void> _addFix_addMissingNamedArgument() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    // Prepare the name of the missing parameter.
    if (this.node is! SimpleIdentifier) {
      return;
    }
    SimpleIdentifier node = this.node;
    String name = node.name;

    // We expect that the node is part of a NamedExpression.
    if (node.parent?.parent is! NamedExpression) {
      return;
    }
    NamedExpression namedExpression = node.parent.parent;

    // We should be in an ArgumentList.
    if (namedExpression.parent is! ArgumentList) {
      return;
    }
    AstNode argumentList = namedExpression.parent;

    // Prepare the invoked element.
    var context = new _ExecutableParameters(astProvider, argumentList.parent);
    if (context == null) {
      return;
    }

    // We cannot add named parameters when there are positional positional.
    if (context.optionalPositional.isNotEmpty) {
      return;
    }

    Future<void> addParameter(int offset, String prefix, String suffix) async {
      // TODO(brianwilkerson) Determine whether this await is necessary.
      await null;
      if (offset != null) {
        var changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(context.file, (builder) {
          builder.addInsertion(offset, (builder) {
            builder.write(prefix);
            builder.writeParameterMatchingArgument(
                namedExpression, 0, new Set<String>());
            builder.write(suffix);
          });
        });
        _addFixFromBuilder(
            changeBuilder, DartFixKind.ADD_MISSING_PARAMETER_NAMED,
            args: [name]);
      }
    }

    if (context.named.isNotEmpty) {
      var prevNode = await context.getParameterNode(context.named.last);
      await addParameter(prevNode?.end, ', ', '');
    } else if (context.required.isNotEmpty) {
      var prevNode = await context.getParameterNode(context.required.last);
      await addParameter(prevNode?.end, ', {', '}');
    } else {
      var parameterList = await context.getParameterList();
      await addParameter(parameterList?.leftParenthesis?.end, '{', '}');
    }
  }

  Future<void> _addFix_addMissingParameter() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    // The error is reported on ArgumentList.
    if (node is! ArgumentList) {
      return;
    }
    ArgumentList argumentList = node;
    List<Expression> arguments = argumentList.arguments;

    // Prepare the invoked element.
    var context = new _ExecutableParameters(astProvider, node.parent);
    if (context == null) {
      return;
    }

    // prepare the argument to add a new parameter for
    int numRequired = context.required.length;
    if (numRequired >= arguments.length) {
      return;
    }
    Expression argument = arguments[numRequired];

    Future<void> addParameter(
        FixKind kind, int offset, String prefix, String suffix) async {
      // TODO(brianwilkerson) Determine whether this await is necessary.
      await null;
      if (offset != null) {
        var changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(context.file, (builder) {
          builder.addInsertion(offset, (builder) {
            builder.write(prefix);
            builder.writeParameterMatchingArgument(
                argument, numRequired, new Set<String>());
            builder.write(suffix);
          });
        });
        _addFixFromBuilder(changeBuilder, kind);
      }
    }

    // Suggest adding a required parameter.
    {
      var kind = DartFixKind.ADD_MISSING_PARAMETER_REQUIRED;
      if (context.required.isNotEmpty) {
        var prevNode = await context.getParameterNode(context.required.last);
        await addParameter(kind, prevNode?.end, ', ', '');
      } else {
        var parameterList = await context.getParameterList();
        var offset = parameterList?.leftParenthesis?.end;
        var suffix = context.executable.parameters.isNotEmpty ? ', ' : '';
        await addParameter(kind, offset, '', suffix);
      }
    }

    // Suggest adding the first optional positional parameter.
    if (context.optionalPositional.isEmpty && context.named.isEmpty) {
      var kind = DartFixKind.ADD_MISSING_PARAMETER_POSITIONAL;
      var prefix = context.required.isNotEmpty ? ', [' : '[';
      if (context.required.isNotEmpty) {
        var prevNode = await context.getParameterNode(context.required.last);
        await addParameter(kind, prevNode?.end, prefix, ']');
      } else {
        var parameterList = await context.getParameterList();
        var offset = parameterList?.leftParenthesis?.end;
        await addParameter(kind, offset, prefix, ']');
      }
    }
  }

  Future<void> _addFix_addMissingRequiredArgument() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    InstanceCreationExpression creation;
    Element targetElement;
    ArgumentList argumentList;

    if (node is SimpleIdentifier) {
      AstNode invocation = node.parent;
      if (invocation is MethodInvocation) {
        targetElement = invocation.methodName.staticElement;
        argumentList = invocation.argumentList;
      } else {
        creation =
            invocation.getAncestor((p) => p is InstanceCreationExpression);
        if (creation != null) {
          targetElement = creation.staticElement;
          argumentList = creation.argumentList;
        }
      }
    }

    if (targetElement is ExecutableElement) {
      // Format: "Missing required argument 'foo"
      List<String> messageParts = error.message.split("'");
      if (messageParts.length < 2) {
        return;
      }
      String missingParameterName = messageParts[1];

      ParameterElement missingParameter = targetElement.parameters.firstWhere(
          (p) => p.name == missingParameterName,
          orElse: () => null);
      if (missingParameter == null) {
        return;
      }

      int offset;
      bool hasTrailingComma = false;
      List<Expression> arguments = argumentList.arguments;
      if (arguments.isEmpty) {
        offset = argumentList.leftParenthesis.end;
      } else {
        Expression lastArgument = arguments.last;
        offset = lastArgument.end;
        hasTrailingComma = lastArgument.endToken.next.type == TokenType.COMMA;
      }

      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addInsertion(offset, (DartEditBuilder builder) {
          if (arguments.isNotEmpty) {
            builder.write(', ');
          }
          String defaultValue =
              getDefaultStringParameterValue(missingParameter);
          builder.write('$missingParameterName: $defaultValue');
          // Insert a trailing comma after Flutter instance creation params.
          if (!hasTrailingComma && flutter.isWidgetExpression(creation)) {
            builder.write(',');
          }
        });
      });
      _addFixFromBuilder(
          changeBuilder, DartFixKind.ADD_MISSING_REQUIRED_ARGUMENT,
          args: [missingParameterName]);
    }
  }

  Future<void> _addFix_addOverrideAnnotation() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    ClassMember member = node.getAncestor((n) => n is ClassMember);
    if (member == null) {
      return;
    }

    //TODO(pq): migrate annotation edit building to change_builder

    // Handle doc comments.
    Token token = member.beginToken;
    if (token is CommentToken) {
      token = (token as CommentToken).parent;
    }

    Position exitPosition = new Position(file, token.offset - 1);
    String indent = utils.getIndent(1);
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addSimpleReplacement(
          range.startLength(token, 0), '@override$eol$indent');
    });
    changeBuilder.setSelection(exitPosition);
    _addFixFromBuilder(changeBuilder, DartFixKind.LINT_ADD_OVERRIDE);
  }

  Future<void> _addFix_addRequiredAnnotation() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addSimpleInsertion(node.parent.offset, '@required ');
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.LINT_ADD_REQUIRED);
  }

  Future<void> _addFix_addStatic() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    FieldDeclaration declaration =
        node.getAncestor((n) => n is FieldDeclaration);
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addSimpleInsertion(declaration.offset, 'static ');
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.ADD_STATIC);
  }

  Future<void> _addFix_boolInsteadOfBoolean() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addSimpleReplacement(range.error(error), 'bool');
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.REPLACE_BOOLEAN_WITH_BOOL);
  }

  Future<void> _addFix_canBeNullAfterNullAware() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    AstNode node = coveredNode;
    if (node is Expression) {
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        AstNode parent = node.parent;
        while (parent != null) {
          if (parent is MethodInvocation && parent.target == node) {
            builder.addSimpleReplacement(range.token(parent.operator), '?.');
          } else if (parent is PropertyAccess && parent.target == node) {
            builder.addSimpleReplacement(range.token(parent.operator), '?.');
          } else {
            break;
          }
          node = parent;
          parent = node.parent;
        }
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.REPLACE_WITH_NULL_AWARE);
    }
  }

  Future<void> _addFix_changeToNearestPreciseValue() async {
    IntegerLiteral integer = node;
    String lexeme = integer.literal.lexeme;
    BigInt precise = BigInt.from(IntegerLiteralImpl.nearestValidDouble(lexeme));
    String correction = lexeme.toLowerCase().contains('x')
        ? '0x${precise.toRadixString(16).toUpperCase()}'
        : precise.toString();
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addSimpleReplacement(range.node(integer), correction);
    });
    _addFixFromBuilder(
        changeBuilder, DartFixKind.CHANGE_TO_NEAREST_PRECISE_VALUE,
        args: [correction]);
  }

  Future<void> _addFix_changeTypeAnnotation() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    AstNode declaration = coveredNode.parent;
    if (declaration is VariableDeclaration &&
        declaration.initializer == coveredNode) {
      AstNode variableList = declaration.parent;
      if (variableList is VariableDeclarationList &&
          variableList.variables.length == 1) {
        TypeAnnotation typeNode = variableList.type;
        if (typeNode != null) {
          Expression initializer = coveredNode;
          DartType newType = initializer.staticType;
          if (newType is InterfaceType || newType is FunctionType) {
            DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
            await changeBuilder.addFileEdit(file,
                (DartFileEditBuilder builder) {
              builder.addReplacement(range.node(typeNode),
                  (DartEditBuilder builder) {
                builder.writeType(newType);
              });
            });
            _addFixFromBuilder(
                changeBuilder, DartFixKind.CHANGE_TYPE_ANNOTATION, args: [
              resolutionMap.typeForTypeName(typeNode),
              newType.displayName
            ]);
          }
        }
      }
    }
  }

  Future<void> _addFix_convertFlutterChild() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    NamedExpression named = flutter.findNamedExpression(node, 'child');
    if (named == null) {
      return;
    }

    // child: widget
    Expression expression = named.expression;
    if (flutter.isWidgetExpression(expression)) {
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        flutter.convertChildToChildren2(
            builder,
            expression,
            named,
            eol,
            utils.getNodeText,
            utils.getLinePrefix,
            utils.getIndent,
            utils.getText,
            range.node);
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.CONVERT_FLUTTER_CHILD);
      return;
    }

    // child: [widget1, widget2]
    if (expression is ListLiteral &&
        expression.elements.every(flutter.isWidgetExpression)) {
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addSimpleReplacement(range.node(named.name), 'children:');
        if (expression.typeArguments == null) {
          builder.addSimpleInsertion(expression.offset, '<Widget>');
        }
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.CONVERT_FLUTTER_CHILD);
    }
  }

  Future<void> _addFix_convertFlutterChildren() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    AstNode node = this.node;
    if (node is SimpleIdentifier &&
        node.name == 'children' &&
        node.parent?.parent is NamedExpression) {
      NamedExpression named = node.parent?.parent;
      Expression expression = named.expression;
      if (expression is ListLiteral && expression.elements.length == 1) {
        Expression widget = expression.elements[0];
        if (flutter.isWidgetExpression(widget)) {
          String widgetText = utils.getNodeText(widget);
          String indentOld = utils.getLinePrefix(widget.offset);
          String indentNew = utils.getLinePrefix(named.offset);
          widgetText = _replaceSourceIndent(widgetText, indentOld, indentNew);

          var builder = new DartChangeBuilder(session);
          await builder.addFileEdit(file, (builder) {
            builder.addReplacement(range.node(named), (builder) {
              builder.write('child: ');
              builder.write(widgetText);
            });
          });
          _addFixFromBuilder(builder, DartFixKind.CONVERT_FLUTTER_CHILDREN);
        }
      }
    }
  }

  Future<void> _addFix_convertToNamedArgument() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    var argumentList = this.node;
    if (argumentList is ArgumentList) {
      // Prepare ExecutableElement.
      ExecutableElement executable;
      var parent = argumentList.parent;
      if (parent is InstanceCreationExpression) {
        executable = parent.staticElement;
      } else if (parent is MethodInvocation) {
        executable = parent.methodName.staticElement;
      }
      if (executable == null) {
        return;
      }

      // Prepare named parameters.
      int numberOfPositionalParameters = 0;
      var namedParameters = <ParameterElement>[];
      for (var parameter in executable.parameters) {
        if (parameter.isNamed) {
          namedParameters.add(parameter);
        } else {
          numberOfPositionalParameters++;
        }
      }
      if (argumentList.arguments.length <= numberOfPositionalParameters) {
        return;
      }

      // Find named parameters for extra arguments.
      var argumentToParameter = <Expression, ParameterElement>{};
      Iterable<Expression> extraArguments =
          argumentList.arguments.skip(numberOfPositionalParameters);
      for (var argument in extraArguments) {
        if (argument is! NamedExpression) {
          ParameterElement uniqueNamedParameter = null;
          for (var namedParameter in namedParameters) {
            if (typeSystem.isSubtypeOf(
                argument.staticType, namedParameter.type)) {
              if (uniqueNamedParameter == null) {
                uniqueNamedParameter = namedParameter;
              } else {
                uniqueNamedParameter = null;
                break;
              }
            }
          }
          if (uniqueNamedParameter != null) {
            argumentToParameter[argument] = uniqueNamedParameter;
            namedParameters.remove(uniqueNamedParameter);
          }
        }
      }
      if (argumentToParameter.isEmpty) {
        return;
      }

      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        for (var argument in argumentToParameter.keys) {
          var parameter = argumentToParameter[argument];
          builder.addSimpleInsertion(argument.offset, '${parameter.name}: ');
        }
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.CONVERT_TO_NAMED_ARGUMENTS);
    }
  }

  Future<void> _addFix_createClass() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    Element prefixElement = null;
    String name = null;
    SimpleIdentifier nameNode;
    if (node is SimpleIdentifier) {
      AstNode parent = node.parent;
      if (parent is PrefixedIdentifier) {
        PrefixedIdentifier prefixedIdentifier = parent;
        prefixElement = prefixedIdentifier.prefix.staticElement;
        if (prefixElement == null) {
          return;
        }
        parent = prefixedIdentifier.parent;
        nameNode = prefixedIdentifier.identifier;
        name = prefixedIdentifier.identifier.name;
      } else {
        nameNode = node;
        name = nameNode.name;
      }
      if (!_mayBeTypeIdentifier(nameNode)) {
        return;
      }
    } else {
      return;
    }
    // prepare environment
    Element targetUnit;
    String prefix = '';
    String suffix = '';
    int offset = -1;
    String filePath;
    if (prefixElement == null) {
      targetUnit = unitElement;
      CompilationUnitMember enclosingMember = node.getAncestor((node) =>
          node is CompilationUnitMember && node.parent is CompilationUnit);
      if (enclosingMember == null) {
        return;
      }
      offset = enclosingMember.end;
      filePath = file;
      prefix = '$eol$eol';
    } else {
      for (ImportElement import in unitLibraryElement.imports) {
        if (prefixElement is PrefixElement && import.prefix == prefixElement) {
          LibraryElement library = import.importedLibrary;
          if (library != null) {
            targetUnit = library.definingCompilationUnit;
            Source targetSource = targetUnit.source;
            try {
              offset = targetSource.contents.data.length;
              filePath = targetSource.fullName;
              prefix = '$eol';
              suffix = '$eol';
            } on FileSystemException {
              // If we can't read the file to get the offset, then we can't
              // create a fix.
            }
            break;
          }
        }
      }
    }
    if (offset < 0) {
      return;
    }
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(filePath, (DartFileEditBuilder builder) {
      builder.addInsertion(offset, (DartEditBuilder builder) {
        builder.write(prefix);
        builder.writeClassDeclaration(name, nameGroupName: 'NAME');
        builder.write(suffix);
      });
      if (prefixElement == null) {
        builder.addLinkedPosition(range.node(node), 'NAME');
      }
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_CLASS, args: [name]);
  }

  /**
   * Here we handle cases when there are no constructors in a class, and the
   * class has uninitialized final fields.
   */
  Future<void> _addFix_createConstructor_forUninitializedFinalFields() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is! SimpleIdentifier || node.parent is! VariableDeclaration) {
      return;
    }

    ClassDeclaration classDeclaration =
        node.getAncestor((node) => node is ClassDeclaration);
    if (classDeclaration == null) {
      return;
    }
    String className = classDeclaration.name.name;
    InterfaceType superType = classDeclaration.declaredElement.supertype;

    // prepare names of uninitialized final fields
    List<String> fieldNames = <String>[];
    for (ClassMember member in classDeclaration.members) {
      if (member is FieldDeclaration) {
        VariableDeclarationList variableList = member.fields;
        if (variableList.isFinal) {
          fieldNames.addAll(variableList.variables
              .where((v) => v.initializer == null)
              .map((v) => v.name.name));
        }
      }
    }
    // prepare location for a new constructor
    ClassMemberLocation targetLocation =
        utils.prepareNewConstructorLocation(classDeclaration);

    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    if (flutter.isExactlyStatelessWidgetType(superType) ||
        flutter.isExactlyStatefulWidgetType(superType)) {
      // Specialize for Flutter widgets.
      ClassElement keyClass =
          await sessionHelper.getClass(flutter.WIDGETS_LIBRARY_URI, 'Key');
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addInsertion(targetLocation.offset, (DartEditBuilder builder) {
          builder.write(targetLocation.prefix);
          builder.write('const ');
          builder.write(className);
          builder.write('({');
          builder.writeType(keyClass.type);
          builder.write(' key');

          List<String> childrenFields = [];
          for (String fieldName in fieldNames) {
            if (fieldName == 'child' || fieldName == 'children') {
              childrenFields.add(fieldName);
              continue;
            }
            builder.write(', this.');
            builder.write(fieldName);
          }
          for (String fieldName in childrenFields) {
            builder.write(', this.');
            builder.write(fieldName);
          }

          builder.write('}) : super(key: key);');
          builder.write(targetLocation.suffix);
        });
      });
    } else {
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addInsertion(targetLocation.offset, (DartEditBuilder builder) {
          builder.write(targetLocation.prefix);
          builder.writeConstructorDeclaration(className,
              fieldNames: fieldNames);
          builder.write(targetLocation.suffix);
        });
      });
    }
    _addFixFromBuilder(
        changeBuilder, DartFixKind.CREATE_CONSTRUCTOR_FOR_FINAL_FIELDS);
  }

  Future<void> _addFix_createConstructor_insteadOfSyntheticDefault() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is! ArgumentList) {
      return;
    }
    if (node.parent is! InstanceCreationExpression) {
      return;
    }
    InstanceCreationExpression instanceCreation = node.parent;
    ConstructorName constructorName = instanceCreation.constructorName;
    // should be synthetic default constructor
    ConstructorElement constructorElement = constructorName.staticElement;
    if (constructorElement == null ||
        !constructorElement.isDefaultConstructor ||
        !constructorElement.isSynthetic) {
      return;
    }
    // prepare target
    if (constructorElement.enclosingElement is! ClassElement) {
      return;
    }
    ClassElement targetElement = constructorElement.enclosingElement;
    // prepare location for a new constructor
    AstNode targetTypeNode = getParsedClassElementNode(targetElement);
    if (targetTypeNode is! ClassDeclaration) {
      return;
    }
    ClassMemberLocation targetLocation =
        utils.prepareNewConstructorLocation(targetTypeNode);
    Source targetSource = targetElement.source;
    String targetFile = targetSource.fullName;
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(targetFile, (DartFileEditBuilder builder) {
      builder.addInsertion(targetLocation.offset, (DartEditBuilder builder) {
        builder.write(targetLocation.prefix);
        builder.writeConstructorDeclaration(targetElement.name,
            argumentList: instanceCreation.argumentList);
        builder.write(targetLocation.suffix);
      });
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_CONSTRUCTOR,
        args: [constructorName]);
  }

  Future<void> _addFix_createConstructor_named() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    SimpleIdentifier name = null;
    ConstructorName constructorName = null;
    InstanceCreationExpression instanceCreation = null;
    if (node is SimpleIdentifier) {
      // name
      name = node as SimpleIdentifier;
      if (name.parent is ConstructorName) {
        constructorName = name.parent as ConstructorName;
        if (constructorName.name == name) {
          // Type.name
          if (constructorName.parent is InstanceCreationExpression) {
            instanceCreation =
                constructorName.parent as InstanceCreationExpression;
            // new Type.name()
            if (instanceCreation.constructorName != constructorName) {
              return;
            }
          }
        }
      }
    }
    // do we have enough information?
    if (instanceCreation == null) {
      return;
    }
    // prepare target interface type
    DartType targetType = constructorName.type.type;
    if (targetType is! InterfaceType) {
      return;
    }
    // prepare location for a new constructor
    ClassElement targetElement = targetType.element as ClassElement;
    AstNode targetTypeNode = getParsedClassElementNode(targetElement);
    if (targetTypeNode is! ClassDeclaration) {
      return;
    }
    ClassMemberLocation targetLocation =
        utils.prepareNewConstructorLocation(targetTypeNode);
    String targetFile = targetElement.source.fullName;
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addInsertion(targetLocation.offset, (DartEditBuilder builder) {
        builder.write(targetLocation.prefix);
        builder.writeConstructorDeclaration(targetElement.name,
            argumentList: instanceCreation.argumentList,
            constructorName: name,
            constructorNameGroupName: 'NAME');
        builder.write(targetLocation.suffix);
      });
      if (targetFile == file) {
        builder.addLinkedPosition(range.node(name), 'NAME');
      }
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_CONSTRUCTOR,
        args: [constructorName]);
  }

  Future<void> _addFix_createConstructorSuperExplicit() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node.parent is! ConstructorDeclaration ||
        node.parent.parent is! ClassDeclaration) {
      return;
    }
    ConstructorDeclaration targetConstructor =
        node.parent as ConstructorDeclaration;
    ClassDeclaration targetClassNode =
        targetConstructor.parent as ClassDeclaration;
    ClassElement targetClassElement = targetClassNode.declaredElement;
    InterfaceType superType = targetClassElement.supertype;
    // add proposals for all super constructors
    for (ConstructorElement superConstructor in superType.constructors) {
      String constructorName = superConstructor.name;
      // skip private
      if (Identifier.isPrivateName(constructorName)) {
        continue;
      }
      List<ConstructorInitializer> initializers =
          targetConstructor.initializers;
      int insertOffset;
      String prefix;
      if (initializers.isEmpty) {
        insertOffset = targetConstructor.parameters.end;
        prefix = ' : ';
      } else {
        ConstructorInitializer lastInitializer =
            initializers[initializers.length - 1];
        insertOffset = lastInitializer.end;
        prefix = ', ';
      }
      String proposalName = _getConstructorProposalName(superConstructor);
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addInsertion(insertOffset, (DartEditBuilder builder) {
          builder.write(prefix);
          // add super constructor name
          builder.write('super');
          if (!isEmpty(constructorName)) {
            builder.write('.');
            builder.addSimpleLinkedEdit('NAME', constructorName);
          }
          // add arguments
          builder.write('(');
          bool firstParameter = true;
          for (ParameterElement parameter in superConstructor.parameters) {
            // skip non-required parameters
            if (parameter.isOptional) {
              break;
            }
            // comma
            if (firstParameter) {
              firstParameter = false;
            } else {
              builder.write(', ');
            }
            // default value
            builder.addSimpleLinkedEdit(
                parameter.name, getDefaultValueCode(parameter.type));
          }
          builder.write(')');
        });
      });
      _addFixFromBuilder(
          changeBuilder, DartFixKind.ADD_SUPER_CONSTRUCTOR_INVOCATION,
          args: [proposalName]);
    }
  }

  Future<void> _addFix_createConstructorSuperImplicit() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    ClassDeclaration targetClassNode =
        node.getAncestor((parent) => parent is ClassDeclaration);
    ClassElement targetClassElement = targetClassNode.declaredElement;
    InterfaceType superType = targetClassElement.supertype;
    String targetClassName = targetClassElement.name;
    // add proposals for all super constructors
    for (ConstructorElement superConstructor in superType.constructors) {
      superConstructor = ConstructorMember.from(superConstructor, superType);
      String constructorName = superConstructor.name;
      // skip private
      if (Identifier.isPrivateName(constructorName)) {
        continue;
      }
      // prepare parameters and arguments
      Iterable<ParameterElement> requiredParameters = superConstructor
          .parameters
          .where((parameter) => parameter.isNotOptional);
      // add proposal
      ClassMemberLocation targetLocation =
          utils.prepareNewConstructorLocation(targetClassNode);
      String proposalName = _getConstructorProposalName(superConstructor);
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addInsertion(targetLocation.offset, (DartEditBuilder builder) {
          void writeParameters(bool includeType) {
            bool firstParameter = true;
            for (ParameterElement parameter in requiredParameters) {
              if (firstParameter) {
                firstParameter = false;
              } else {
                builder.write(', ');
              }
              String parameterName = parameter.displayName;
              if (parameterName.length > 1 && parameterName.startsWith('_')) {
                parameterName = parameterName.substring(1);
              }
              if (includeType && builder.writeType(parameter.type)) {
                builder.write(' ');
              }
              builder.write(parameterName);
            }
          }

          builder.write(targetLocation.prefix);
          builder.write(targetClassName);
          if (!constructorName.isEmpty) {
            builder.write('.');
            builder.addSimpleLinkedEdit('NAME', constructorName);
          }
          builder.write('(');
          writeParameters(true);
          builder.write(') : super');
          if (!constructorName.isEmpty) {
            builder.write('.');
            builder.addSimpleLinkedEdit('NAME', constructorName);
          }
          builder.write('(');
          writeParameters(false);
          builder.write(');');
          builder.write(targetLocation.suffix);
        });
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_CONSTRUCTOR_SUPER,
          args: [proposalName]);
    }
  }

  Future<void> _addFix_createField() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is! SimpleIdentifier) {
      return;
    }
    SimpleIdentifier nameNode = node;
    String name = nameNode.name;
    // prepare target Expression
    Expression target;
    {
      AstNode nameParent = nameNode.parent;
      if (nameParent is PrefixedIdentifier) {
        target = nameParent.prefix;
      } else if (nameParent is PropertyAccess) {
        target = nameParent.realTarget;
      }
    }
    // prepare target ClassElement
    bool staticModifier = false;
    ClassElement targetClassElement;
    if (target != null) {
      // prepare target interface type
      DartType targetType = target.staticType;
      if (targetType is! InterfaceType) {
        return;
      }
      targetClassElement = targetType.element;
      // maybe static
      if (target is Identifier) {
        Identifier targetIdentifier = target;
        Element targetElement = targetIdentifier.staticElement;
        if (targetElement == null) {
          return;
        }
        staticModifier = targetElement.kind == ElementKind.CLASS;
      }
    } else {
      targetClassElement = getEnclosingClassElement(node);
      if (targetClassElement == null) {
        return;
      }
      staticModifier = _inStaticContext();
    }
    if (targetClassElement.librarySource.isInSystemLibrary) {
      return;
    }
    utils.targetClassElement = targetClassElement;
    // prepare target ClassDeclaration
    AstNode targetTypeNode = getParsedClassElementNode(targetClassElement);
    if (targetTypeNode is! ClassDeclaration) {
      return;
    }
    ClassDeclaration targetClassNode = targetTypeNode;
    // prepare location
    ClassMemberLocation targetLocation =
        _getUtilsFor(targetClassNode).prepareNewFieldLocation(targetClassNode);
    // build field source
    Source targetSource = targetClassElement.source;
    String targetFile = targetSource.fullName;
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(targetFile, (DartFileEditBuilder builder) {
      Expression fieldTypeNode = climbPropertyAccess(nameNode);
      DartType fieldType = _inferUndefinedExpressionType(fieldTypeNode);
      builder.addInsertion(targetLocation.offset, (DartEditBuilder builder) {
        builder.write(targetLocation.prefix);
        builder.writeFieldDeclaration(name,
            isStatic: staticModifier,
            nameGroupName: 'NAME',
            type: fieldType,
            typeGroupName: 'TYPE');
        builder.write(targetLocation.suffix);
      });
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_FIELD, args: [name]);
  }

  Future<void> _addFix_createField_initializingFormal() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    //
    // Ensure that we are in an initializing formal parameter.
    //
    FieldFormalParameter parameter =
        node.getAncestor((node) => node is FieldFormalParameter);
    if (parameter == null) {
      return;
    }
    ClassDeclaration targetClassNode =
        parameter.getAncestor((node) => node is ClassDeclaration);
    if (targetClassNode == null) {
      return;
    }
    SimpleIdentifier nameNode = parameter.identifier;
    String name = nameNode.name;
    ClassMemberLocation targetLocation =
        utils.prepareNewFieldLocation(targetClassNode);
    //
    // Add proposal.
    //
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      DartType fieldType = parameter.type?.type;
      builder.addInsertion(targetLocation.offset, (DartEditBuilder builder) {
        builder.write(targetLocation.prefix);
        builder.writeFieldDeclaration(name,
            nameGroupName: 'NAME', type: fieldType, typeGroupName: 'TYPE');
        builder.write(targetLocation.suffix);
      });
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_FIELD, args: [name]);
  }

  Future<void> _addFix_createFunction_forFunctionType() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is SimpleIdentifier) {
      SimpleIdentifier nameNode = node as SimpleIdentifier;
      // prepare argument expression (to get parameter)
      ClassElement targetElement;
      Expression argument;
      {
        Expression target = getQualifiedPropertyTarget(node);
        if (target != null) {
          DartType targetType = target.staticType;
          if (targetType != null && targetType.element is ClassElement) {
            targetElement = targetType.element as ClassElement;
            argument = target.parent as Expression;
          } else {
            return;
          }
        } else {
          ClassDeclaration enclosingClass =
              node.getAncestor((node) => node is ClassDeclaration);
          targetElement = enclosingClass?.declaredElement;
          argument = nameNode;
        }
      }
      argument = stepUpNamedExpression(argument);
      // should be argument of some invocation
      ParameterElement parameterElement = argument.staticParameterElement;
      if (parameterElement == null) {
        return;
      }
      // should be parameter of function type
      DartType parameterType = parameterElement.type;
      if (parameterType is InterfaceType && parameterType.isDartCoreFunction) {
        ExecutableElement element = new MethodElementImpl('', -1);
        parameterType = new FunctionTypeImpl(element);
      }
      if (parameterType is! FunctionType) {
        return;
      }
      FunctionType functionType = parameterType as FunctionType;
      // add proposal
      if (targetElement != null) {
        await _addProposal_createFunction_method(targetElement, functionType);
      } else {
        await _addProposal_createFunction_function(functionType);
      }
    }
  }

  Future<void> _addFix_createGetter() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is! SimpleIdentifier) {
      return;
    }
    SimpleIdentifier nameNode = node;
    String name = nameNode.name;
    if (!nameNode.inGetterContext()) {
      return;
    }
    // prepare target Expression
    Expression target;
    {
      AstNode nameParent = nameNode.parent;
      if (nameParent is PrefixedIdentifier) {
        target = nameParent.prefix;
      } else if (nameParent is PropertyAccess) {
        target = nameParent.realTarget;
      }
    }
    // prepare target ClassElement
    bool staticModifier = false;
    ClassElement targetClassElement;
    if (target != null) {
      // prepare target interface type
      DartType targetType = target.staticType;
      if (targetType is! InterfaceType) {
        return;
      }
      targetClassElement = targetType.element;
      // maybe static
      if (target is Identifier) {
        Identifier targetIdentifier = target;
        Element targetElement = targetIdentifier.staticElement;
        staticModifier = targetElement?.kind == ElementKind.CLASS;
      }
    } else {
      targetClassElement = getEnclosingClassElement(node);
      if (targetClassElement == null) {
        return;
      }
      staticModifier = _inStaticContext();
    }
    if (targetClassElement.librarySource.isInSystemLibrary) {
      return;
    }
    utils.targetClassElement = targetClassElement;
    // prepare target ClassDeclaration
    AstNode targetTypeNode = getParsedClassElementNode(targetClassElement);
    if (targetTypeNode is! ClassDeclaration) {
      return;
    }
    ClassDeclaration targetClassNode = targetTypeNode;
    // prepare location
    ClassMemberLocation targetLocation =
        _getUtilsFor(targetClassNode).prepareNewGetterLocation(targetClassNode);
    // build method source
    Source targetSource = targetClassElement.source;
    String targetFile = targetSource.fullName;
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(targetFile, (DartFileEditBuilder builder) {
      builder.addInsertion(targetLocation.offset, (DartEditBuilder builder) {
        Expression fieldTypeNode = climbPropertyAccess(nameNode);
        DartType fieldType = _inferUndefinedExpressionType(fieldTypeNode);
        builder.write(targetLocation.prefix);
        builder.writeGetterDeclaration(name,
            isStatic: staticModifier,
            nameGroupName: 'NAME',
            returnType: fieldType,
            returnTypeGroupName: 'TYPE');
        builder.write(targetLocation.suffix);
      });
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_GETTER, args: [name]);
  }

  Future<void> _addFix_createImportUri() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    // TODO(brianwilkerson) Generalize this to allow other valid string literals.
    // TODO(brianwilkerson) Support the case where the node's parent is a Configuration.
    if (node is SimpleStringLiteral && node.parent is ImportDirective) {
      ImportDirective importDirective = node.parent;
      Source source = importDirective.uriSource;
      if (source != null) {
        String file = source.fullName;
        if (isAbsolute(file) && AnalysisEngine.isDartFileName(file)) {
          String libName = _computeLibraryName(file);
          try {
            DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
            await changeBuilder.addFileEdit(source.fullName,
                (DartFileEditBuilder builder) {
              builder.addSimpleInsertion(0, 'library $libName;$eol$eol');
            });
            _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_FILE,
                args: [source.shortName]);
          } on AnalysisException {
            // Ignore the exception and just don't create a fix.
          }
        }
      }
    }
  }

  Future<void> _addFix_createLocalVariable() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is! SimpleIdentifier) {
      return;
    }
    SimpleIdentifier nameNode = node;
    String name = nameNode.name;
    // if variable is assigned, convert assignment into declaration
    if (node.parent is AssignmentExpression) {
      AssignmentExpression assignment = node.parent;
      if (assignment.leftHandSide == node &&
          assignment.operator.type == TokenType.EQ &&
          assignment.parent is ExpressionStatement) {
        DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
          builder.addSimpleInsertion(node.offset, 'var ');
        });
        _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_LOCAL_VARIABLE,
            args: [name]);
        return;
      }
    }
    // prepare target Statement
    Statement target = node.getAncestor((x) => x is Statement);
    if (target == null) {
      return;
    }
    String prefix = utils.getNodePrefix(target);
    // compute type
    DartType type = _inferUndefinedExpressionType(node);
    if (!(type == null ||
        type is InterfaceType ||
        type is FunctionType &&
            type.element != null &&
            !type.element.isSynthetic)) {
      return;
    }
    // build variable declaration source
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addInsertion(target.offset, (DartEditBuilder builder) {
        builder.writeLocalVariableDeclaration(name,
            nameGroupName: 'NAME', type: type, typeGroupName: 'TYPE');
        builder.write(eol);
        builder.write(prefix);
      });
      builder.addLinkedPosition(range.node(node), 'NAME');
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_LOCAL_VARIABLE,
        args: [name]);
  }

  Future<void> _addFix_createMissingOverrides() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node.parent is! ClassDeclaration) {
      return;
    }
    ClassDeclaration targetClass = node.parent as ClassDeclaration;
    ClassElement targetClassElement = targetClass.declaredElement;
    utils.targetClassElement = targetClassElement;
    List<ExecutableElement> elements =
        InheritanceOverrideVerifier.missingOverrides(targetClass).toList();
    // sort by name, getters before setters
    elements.sort((Element a, Element b) {
      int names = compareStrings(a.displayName, b.displayName);
      if (names != 0) {
        return names;
      }
      if (a.kind == ElementKind.GETTER) {
        return -1;
      }
      return 1;
    });
    int numElements = elements.length;

    ClassMemberLocation location =
        utils.prepareNewClassMemberLocation(targetClass, (_) => true);

    String prefix = utils.getIndent(1);
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addInsertion(location.offset, (DartEditBuilder builder) {
        // TODO(brianwilkerson) Compare with builder.writeOverrideOfInheritedMember
        // The builder method doesn't merge getter/setter pairs into fields.

        // Separator management.
        int numOfMembersWritten = 0;
        void addSeparatorBetweenDeclarations() {
          if (numOfMembersWritten == 0) {
            builder.write(location.prefix);
          } else {
            builder.write(eol); // after the previous member
            builder.write(eol); // empty line separator
            builder.write(prefix);
          }
          numOfMembersWritten++;
        }

        // merge getter/setter pairs into fields
        for (int i = 0; i < elements.length; i++) {
          ExecutableElement element = elements[i];
          if (element.kind == ElementKind.GETTER && i + 1 < elements.length) {
            ExecutableElement nextElement = elements[i + 1];
            if (nextElement.kind == ElementKind.SETTER) {
              // remove this and the next elements, adjust iterator
              elements.removeAt(i + 1);
              elements.removeAt(i);
              i--;
              numElements--;
              // separator
              addSeparatorBetweenDeclarations();
              // @override
              builder.write('@override');
              builder.write(eol);
              // add field
              builder.write(prefix);
              builder.writeType(element.type.returnType, required: true);
              builder.write(' ');
              builder.write(element.name);
              builder.write(';');
            }
          }
        }
        // add elements
        for (ExecutableElement element in elements) {
          addSeparatorBetweenDeclarations();
          _addFix_createMissingOverridesForBuilder(
              builder, targetClass, element);
        }
        builder.write(location.suffix);
      });
    });
    changeBuilder.setSelection(new Position(file, location.offset));
    _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_MISSING_OVERRIDES,
        args: [numElements]);
  }

  void _addFix_createMissingOverridesForBuilder(DartEditBuilder builder,
      ClassDeclaration targetClass, ExecutableElement element) {
    utils.targetExecutableElement = element;
    // prepare environment
    String prefix = utils.getIndent(1);
    String prefix2 = utils.getIndent(2);
    // may be property
    ElementKind elementKind = element.kind;
    bool isGetter = elementKind == ElementKind.GETTER;
    bool isSetter = elementKind == ElementKind.SETTER;
    bool isMethod = elementKind == ElementKind.METHOD;
    bool isOperator = isMethod && (element as MethodElement).isOperator;
    if (isGetter) {
      builder.write('// TODO: implement ${element.displayName}');
      builder.write(eol);
      builder.write(prefix);
    }
    // @override
    builder.write('@override');
    builder.write(eol);
    builder.write(prefix);
    // return type
    if (!isSetter) {
      if (builder.writeType(element.type.returnType,
          methodBeingCopied: element)) {
        builder.write(' ');
      }
    }
    // keyword
    if (isGetter) {
      builder.write('get ');
    } else if (isSetter) {
      builder.write('set ');
    } else if (isOperator) {
      builder.write('operator ');
    }
    // name
    builder.write(element.displayName);
    builder.writeTypeParameters(element.typeParameters,
        methodBeingCopied: element);
    // parameters + body
    if (isGetter) {
      builder.write(' => null;');
    } else {
      List<ParameterElement> parameters = element.parameters;
      builder.writeParameters(parameters, methodBeingCopied: element);
      builder.write(' {');
      // TO-DO
      builder.write(eol);
      builder.write(prefix2);
      builder.write('// TODO: implement ${element.displayName}');
      builder.write(eol);
      // close method
      builder.write(prefix);
      builder.write('}');
    }
    utils.targetExecutableElement = null;
  }

  Future<void> _addFix_createMixin() async {
    Element prefixElement = null;
    String name = null;
    SimpleIdentifier nameNode;
    if (node is SimpleIdentifier) {
      AstNode parent = node.parent;
      if (parent is PrefixedIdentifier) {
        if (parent.parent is InstanceCreationExpression) {
          return;
        }
        PrefixedIdentifier prefixedIdentifier = parent;
        prefixElement = prefixedIdentifier.prefix.staticElement;
        if (prefixElement == null) {
          return;
        }
        parent = prefixedIdentifier.parent;
        nameNode = prefixedIdentifier.identifier;
        name = prefixedIdentifier.identifier.name;
      } else if (parent is TypeName &&
          parent.parent is ConstructorName &&
          parent.parent.parent is InstanceCreationExpression) {
        return;
      } else {
        nameNode = node;
        name = nameNode.name;
      }
      if (!_mayBeTypeIdentifier(nameNode)) {
        return;
      }
    } else {
      return;
    }
    // prepare environment
    Element targetUnit;
    String prefix = '';
    String suffix = '';
    int offset = -1;
    String filePath;
    if (prefixElement == null) {
      targetUnit = unitElement;
      CompilationUnitMember enclosingMember = node.getAncestor((node) =>
          node is CompilationUnitMember && node.parent is CompilationUnit);
      if (enclosingMember == null) {
        return;
      }
      offset = enclosingMember.end;
      filePath = file;
      prefix = '$eol$eol';
    } else {
      for (ImportElement import in unitLibraryElement.imports) {
        if (prefixElement is PrefixElement && import.prefix == prefixElement) {
          LibraryElement library = import.importedLibrary;
          if (library != null) {
            targetUnit = library.definingCompilationUnit;
            Source targetSource = targetUnit.source;
            try {
              offset = targetSource.contents.data.length;
              filePath = targetSource.fullName;
              prefix = '$eol';
              suffix = '$eol';
            } on FileSystemException {
              // If we can't read the file to get the offset, then we can't
              // create a fix.
            }
            break;
          }
        }
      }
    }
    if (offset < 0) {
      return;
    }
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(filePath, (DartFileEditBuilder builder) {
      builder.addInsertion(offset, (DartEditBuilder builder) {
        builder.write(prefix);
        builder.writeMixinDeclaration(name, nameGroupName: 'NAME');
        builder.write(suffix);
      });
      if (prefixElement == null) {
        builder.addLinkedPosition(range.node(node), 'NAME');
      }
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_MIXIN, args: [name]);
  }

  Future<void> _addFix_createNoSuchMethod() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node.parent is! ClassDeclaration) {
      return;
    }
    ClassDeclaration targetClass = node.parent as ClassDeclaration;
    // prepare environment
    String prefix = utils.getIndent(1);
    int insertOffset = targetClass.end - 1;
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addInsertion(insertOffset, (DartEditBuilder builder) {
        builder.selectHere();
        // insert empty line before existing member
        if (!targetClass.members.isEmpty) {
          builder.write(eol);
        }
        // append method
        builder.write(prefix);
        builder.write(
            'noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);');
        builder.write(eol);
      });
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_NO_SUCH_METHOD);
  }

  Future<void> _addFix_createPartUri() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    // TODO(brianwilkerson) Generalize this to allow other valid string literals.
    if (node is SimpleStringLiteral && node.parent is PartDirective) {
      PartDirective partDirective = node.parent;
      Source source = partDirective.uriSource;
      if (source != null) {
        String libName = unitLibraryElement.name;
        DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(source.fullName,
            (DartFileEditBuilder builder) {
          // TODO(brianwilkerson) Consider using the URI rather than name
          builder.addSimpleInsertion(0, 'part of $libName;$eol$eol');
        });
        _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_FILE,
            args: [source.shortName]);
      }
    }
  }

  Future<void> _addFix_illegalAsyncReturnType() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    // prepare the existing type
    TypeAnnotation typeName = node.getAncestor((n) => n is TypeAnnotation);
    TypeProvider typeProvider = this.typeProvider;
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.replaceTypeWithFuture(typeName, typeProvider);
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.REPLACE_RETURN_TYPE_FUTURE);
  }

  Future<void> _addFix_importLibrary(FixKind kind, Uri library) async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    String uriText;
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      uriText = builder.importLibrary(library);
    });
    _addFixFromBuilder(changeBuilder, kind, args: [uriText]);
  }

  Future<void> _addFix_importLibrary_withElement(String name,
      List<ElementKind> elementKinds, TopLevelDeclarationKind kind2) async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    // ignore if private
    if (name.startsWith('_')) {
      return;
    }
    // may be there is an existing import,
    // but it is with prefix and we don't use this prefix
    Set<Source> alreadyImportedWithPrefix = new Set<Source>();
    for (ImportElement imp in unitLibraryElement.imports) {
      // prepare element
      LibraryElement libraryElement = imp.importedLibrary;
      Element element = getExportedElement(libraryElement, name);
      if (element == null) {
        continue;
      }
      if (element is PropertyAccessorElement) {
        element = (element as PropertyAccessorElement).variable;
      }
      if (!elementKinds.contains(element.kind)) {
        continue;
      }
      // may be apply prefix
      PrefixElement prefix = imp.prefix;
      if (prefix != null) {
        DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
          builder.addSimpleReplacement(
              range.startLength(node, 0), '${prefix.displayName}.');
        });
        _addFixFromBuilder(changeBuilder, DartFixKind.IMPORT_LIBRARY_PREFIX,
            args: [libraryElement.displayName, prefix.displayName]);
        continue;
      }
      // may be update "show" directive
      List<NamespaceCombinator> combinators = imp.combinators;
      if (combinators.length == 1 && combinators[0] is ShowElementCombinator) {
        ShowElementCombinator showCombinator =
            combinators[0] as ShowElementCombinator;
        // prepare new set of names to show
        Set<String> showNames = new SplayTreeSet<String>();
        showNames.addAll(showCombinator.shownNames);
        showNames.add(name);
        // prepare library name - unit name or 'dart:name' for SDK library
        String libraryName =
            libraryElement.definingCompilationUnit.source.uri.toString();
        if (libraryElement.isInSdk) {
          libraryName = libraryElement.source.shortName;
        }
        // don't add this library again
        alreadyImportedWithPrefix.add(libraryElement.source);
        // update library
        String newShowCode = 'show ${showNames.join(', ')}';
        int offset = showCombinator.offset;
        int length = showCombinator.end - offset;
        String libraryFile = unitLibraryElement.source.fullName;
        DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(libraryFile,
            (DartFileEditBuilder builder) {
          builder.addSimpleReplacement(
              new SourceRange(offset, length), newShowCode);
        });
        _addFixFromBuilder(changeBuilder, DartFixKind.IMPORT_LIBRARY_SHOW,
            args: [libraryName]);
      }
    }
    // Find new top-level declarations.
    {
      List<TopLevelDeclarationInSource> declarations =
          await getTopLevelDeclarations(name);
      for (TopLevelDeclarationInSource declaration in declarations) {
        // Check the kind.
        if (declaration.declaration.kind != kind2) {
          continue;
        }
        // Check the source.
        Source librarySource = declaration.source;
        if (alreadyImportedWithPrefix.contains(librarySource)) {
          continue;
        }
        if (!_isSourceVisibleToLibrary(librarySource)) {
          continue;
        }
        // Compute the fix kind.
        FixKind fixKind;
        if (librarySource.isInSystemLibrary) {
          fixKind = DartFixKind.IMPORT_LIBRARY_SDK;
        } else if (_isLibSrcPath(librarySource.fullName)) {
          // Bad: non-API.
          fixKind = DartFixKind.IMPORT_LIBRARY_PROJECT3;
        } else if (declaration.isExported) {
          // Ugly: exports.
          fixKind = DartFixKind.IMPORT_LIBRARY_PROJECT2;
        } else {
          // Good: direct declaration.
          fixKind = DartFixKind.IMPORT_LIBRARY_PROJECT1;
        }
        // Add the fix.
        await _addFix_importLibrary(fixKind, librarySource.uri);
      }
    }
  }

  Future<void> _addFix_importLibrary_withFunction() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is SimpleIdentifier && node.parent is MethodInvocation) {
      MethodInvocation invocation = node.parent as MethodInvocation;
      if (invocation.realTarget == null && invocation.methodName == node) {
        String name = (node as SimpleIdentifier).name;
        await _addFix_importLibrary_withElement(name,
            const [ElementKind.FUNCTION], TopLevelDeclarationKind.function);
      }
    }
  }

  Future<void> _addFix_importLibrary_withTopLevelVariable() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is SimpleIdentifier) {
      String name = (node as SimpleIdentifier).name;
      await _addFix_importLibrary_withElement(
          name,
          const [ElementKind.TOP_LEVEL_VARIABLE],
          TopLevelDeclarationKind.variable);
    }
  }

  Future<void> _addFix_importLibrary_withType() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (_mayBeTypeIdentifier(node)) {
      String typeName = (node as SimpleIdentifier).name;
      await _addFix_importLibrary_withElement(
          typeName,
          const [ElementKind.CLASS, ElementKind.FUNCTION_TYPE_ALIAS],
          TopLevelDeclarationKind.type);
    } else if (_mayBeImplicitConstructor(node)) {
      String typeName = (node as SimpleIdentifier).name;
      await _addFix_importLibrary_withElement(
          typeName, const [ElementKind.CLASS], TopLevelDeclarationKind.type);
    }
  }

  Future<void> _addFix_insertSemicolon() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (error.message.contains("';'")) {
      if (_isAwaitNode()) {
        return;
      }
      int insertOffset = error.offset + error.length;
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addSimpleInsertion(insertOffset, ';');
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.INSERT_SEMICOLON);
    }
  }

  Future<void> _addFix_isNotEmpty() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is! PrefixExpression) {
      return;
    }
    PrefixExpression prefixExpression = node;
    Token negation = prefixExpression.operator;
    if (negation.type != TokenType.BANG) {
      return;
    }
    SimpleIdentifier identifier;
    Expression expression = prefixExpression.operand;
    if (expression is PrefixedIdentifier) {
      identifier = expression.identifier;
    } else if (expression is PropertyAccess) {
      identifier = expression.propertyName;
    } else {
      return;
    }
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addDeletion(range.token(negation));
      builder.addSimpleReplacement(range.node(identifier), 'isNotEmpty');
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.USE_IS_NOT_EMPTY);
  }

  Future<void> _addFix_isNotNull() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (coveredNode is IsExpression) {
      IsExpression isExpression = coveredNode as IsExpression;
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder
            .addReplacement(range.endEnd(isExpression.expression, isExpression),
                (DartEditBuilder builder) {
          builder.write(' != null');
        });
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.USE_NOT_EQ_NULL);
    }
  }

  Future<void> _addFix_isNull() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (coveredNode is IsExpression) {
      IsExpression isExpression = coveredNode as IsExpression;
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder
            .addReplacement(range.endEnd(isExpression.expression, isExpression),
                (DartEditBuilder builder) {
          builder.write(' == null');
        });
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.USE_EQ_EQ_NULL);
    }
  }

  Future<void> _addFix_makeEnclosingClassAbstract() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    ClassDeclaration enclosingClass =
        node.getAncestor((node) => node is ClassDeclaration);
    if (enclosingClass == null) {
      return;
    }
    String className = enclosingClass.name.name;
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addSimpleInsertion(
          enclosingClass.classKeyword.offset, 'abstract ');
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.MAKE_CLASS_ABSTRACT,
        args: [className]);
  }

  Future<void> _addFix_makeFieldNotFinal() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    AstNode node = this.node;
    if (node is SimpleIdentifier &&
        node.staticElement is PropertyAccessorElement) {
      PropertyAccessorElement getter = node.staticElement;
      if (getter.isGetter &&
          getter.isSynthetic &&
          !getter.variable.isSynthetic &&
          getter.variable.setter == null &&
          getter.enclosingElement is ClassElement) {
        AstNode name =
            await astProvider.getParsedNameForElement(getter.variable);
        AstNode variable = name?.parent;
        if (variable is VariableDeclaration &&
            variable.parent is VariableDeclarationList &&
            variable.parent.parent is FieldDeclaration) {
          VariableDeclarationList declarationList = variable.parent;
          Token keywordToken = declarationList.keyword;
          if (declarationList.variables.length == 1 &&
              keywordToken.keyword == Keyword.FINAL) {
            DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
            await changeBuilder.addFileEdit(file,
                (DartFileEditBuilder builder) {
              if (declarationList.type != null) {
                builder.addReplacement(
                    range.startStart(keywordToken, declarationList.type),
                    (DartEditBuilder builder) {});
              } else {
                builder.addReplacement(range.startStart(keywordToken, variable),
                    (DartEditBuilder builder) {
                  builder.write('var ');
                });
              }
            });
            String fieldName = getter.variable.displayName;
            _addFixFromBuilder(changeBuilder, DartFixKind.MAKE_FIELD_NOT_FINAL,
                args: [fieldName]);
          }
        }
      }
    }
  }

  Future<void> _addFix_makeVariableFinal() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    AstNode node = this.node;
    if (node is SimpleIdentifier && node.parent is VariableDeclaration) {
      VariableDeclaration declaration = node.parent;
      VariableDeclarationList list = declaration.parent;
      if (list.variables.length == 1) {
        DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
          if (list.keyword == null) {
            builder.addSimpleInsertion(list.offset, 'final ');
          } else if (list.keyword.keyword == Keyword.VAR) {
            builder.addSimpleReplacement(range.token(list.keyword), 'final');
          }
        });
        _addFixFromBuilder(changeBuilder, DartFixKind.MAKE_FINAL);
      }
    }
  }

  Future<void> _addFix_moveTypeArgumentsToClass() async {
    if (coveredNode is TypeArgumentList) {
      TypeArgumentList typeArguments = coveredNode;
      if (typeArguments.parent is! TypeName) {
        return;
      }
      TypeName typeName = typeArguments.parent;
      if (typeName.typeArguments != null) {
        return;
      }
      Element element = typeName.type.element;
      if (element is ClassElement &&
          element.typeParameters != null &&
          element.typeParameters.length == typeArguments.arguments.length) {
        DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
          String argumentText = utils.getNodeText(typeArguments);
          builder.addSimpleInsertion(typeName.end, argumentText);
          builder.addDeletion(range.node(typeArguments));
        });
        _addFixFromBuilder(
            changeBuilder, DartFixKind.MOVE_TYPE_ARGUMENTS_TO_CLASS);
      }
    }
  }

  Future<void> _addFix_nonBoolCondition_addNotNull() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addSimpleInsertion(error.offset + error.length, ' != null');
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.ADD_NE_NULL);
  }

  Future<void> _addFix_removeAwait() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    final awaitExpression = node;
    if (awaitExpression is AwaitExpression) {
      final awaitToken = awaitExpression.awaitKeyword;
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addDeletion(range.startStart(awaitToken, awaitToken.next));
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.REMOVE_AWAIT);
    }
  }

  Future<void> _addFix_removeDeadCode() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    AstNode coveringNode = this.coveredNode;
    if (coveringNode is Expression) {
      AstNode parent = coveredNode.parent;
      if (parent is BinaryExpression) {
        if (parent.rightOperand == coveredNode) {
          DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
          await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
            builder.addDeletion(range.endEnd(parent.leftOperand, coveredNode));
          });
          _addFixFromBuilder(changeBuilder, DartFixKind.REMOVE_DEAD_CODE);
        }
      }
    } else if (coveringNode is Block) {
      Block block = coveringNode;
      List<Statement> statementsToRemove = <Statement>[];
      for (Statement statement in block.statements) {
        if (range.node(statement).intersects(errorRange)) {
          statementsToRemove.add(statement);
        }
      }
      if (statementsToRemove.isNotEmpty) {
        SourceRange rangeToRemove =
            utils.getLinesRangeStatements(statementsToRemove);
        DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
          builder.addDeletion(rangeToRemove);
        });
        _addFixFromBuilder(changeBuilder, DartFixKind.REMOVE_DEAD_CODE);
      }
    } else if (coveringNode is Statement) {
      SourceRange rangeToRemove =
          utils.getLinesRangeStatements(<Statement>[coveringNode]);
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addDeletion(rangeToRemove);
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.REMOVE_DEAD_CODE);
    }
  }

  Future<void> _addFix_removeEmptyCatch() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addDeletion(utils.getLinesRange(range.node(node.parent)));
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.REMOVE_EMPTY_CATCH);
  }

  Future<void> _addFix_removeEmptyConstructorBody() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addSimpleReplacement(
          utils.getLinesRange(range.node(node.parent)), ';');
    });
    _addFixFromBuilder(
        changeBuilder, DartFixKind.REMOVE_EMPTY_CONSTRUCTOR_BODY);
  }

  Future<void> _addFix_removeEmptyElse() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    IfStatement ifStatement = node.parent;
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addDeletion(utils.getLinesRange(
          range.startEnd(ifStatement.elseKeyword, ifStatement.elseStatement)));
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.REMOVE_EMPTY_ELSE);
  }

  Future<void> _addFix_removeEmptyStatement() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    EmptyStatement emptyStatement = node;
    if (emptyStatement.parent is Block) {
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addDeletion(utils.getLinesRange(range.node(emptyStatement)));
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.REMOVE_EMPTY_STATEMENT);
    } else {
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        Token previous = emptyStatement.findPrevious(emptyStatement.beginToken);
        if (previous != null) {
          builder.addSimpleReplacement(
              range.endEnd(previous, emptyStatement), ' {}');
        }
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.REPLACE_WITH_BRACKETS);
    }
  }

  Future<void> _addFix_removeInitializer() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    // Retrieve the linted node.
    VariableDeclaration ancestor =
        node.getAncestor((a) => a is VariableDeclaration);
    if (ancestor == null) {
      return;
    }
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addDeletion(range.endEnd(ancestor.name, ancestor.initializer));
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.REMOVE_INITIALIZER);
  }

  Future<void> _addFix_removeInterpolationBraces() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    AstNode node = this.node;
    if (node is InterpolationExpression) {
      Token right = node.rightBracket;
      if (node.expression != null && right != null) {
        DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
          builder.addSimpleReplacement(
              range.startStart(node, node.expression), r'$');
          builder.addDeletion(range.token(right));
        });
        _addFixFromBuilder(
            changeBuilder, DartFixKind.LINT_REMOVE_INTERPOLATION_BRACES);
      } else {}
    }
  }

  Future<void> _addFix_removeMethodDeclaration() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    MethodDeclaration declaration =
        node.getAncestor((node) => node is MethodDeclaration);
    if (declaration != null) {
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addDeletion(utils.getLinesRange(range.node(declaration)));
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.REMOVE_METHOD_DECLARATION);
    }
  }

  Future<void> _addFix_removeParameters_inGetterDeclaration() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is MethodDeclaration) {
      // Support for the analyzer error.
      MethodDeclaration method = node as MethodDeclaration;
      SimpleIdentifier name = method.name;
      FunctionBody body = method.body;
      if (name != null && body != null) {
        DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
          builder.addSimpleReplacement(range.endStart(name, body), ' ');
        });
        _addFixFromBuilder(
            changeBuilder, DartFixKind.REMOVE_PARAMETERS_IN_GETTER_DECLARATION);
      }
    } else if (node is FormalParameterList) {
      // Support for the fasta error.
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addDeletion(range.node(node));
      });
      _addFixFromBuilder(
          changeBuilder, DartFixKind.REMOVE_PARAMETERS_IN_GETTER_DECLARATION);
    }
  }

  Future<void> _addFix_removeParentheses_inGetterInvocation() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is SimpleIdentifier && node.parent is MethodInvocation) {
      MethodInvocation invocation = node.parent as MethodInvocation;
      if (invocation.methodName == node && invocation.target != null) {
        DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
          builder.addDeletion(range.endEnd(node, invocation));
        });
        _addFixFromBuilder(
            changeBuilder, DartFixKind.REMOVE_PARENTHESIS_IN_GETTER_INVOCATION);
      }
    }
  }

  Future<void> _addFix_removeThisExpression() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    final thisExpression = node is ThisExpression
        ? node
        : node.getAncestor((node) => node is ThisExpression);
    final parent = thisExpression?.parent;
    if (parent is PropertyAccess) {
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addDeletion(range.startEnd(parent, parent.operator));
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.REMOVE_THIS_EXPRESSION);
    } else if (parent is MethodInvocation) {
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addDeletion(range.startEnd(parent, parent.operator));
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.REMOVE_THIS_EXPRESSION);
    }
  }

  Future<void> _addFix_removeTypeAnnotation() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    final TypeAnnotation type =
        node.getAncestor((node) => node is TypeAnnotation);
    if (type != null) {
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addDeletion(range.startStart(type, type.endToken.next));
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.REMOVE_TYPE_NAME);
    }
  }

  Future<void> _addFix_removeTypeArguments() async {
    if (coveredNode is TypeArgumentList) {
      TypeArgumentList typeArguments = coveredNode;
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addDeletion(range.node(typeArguments));
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.REMOVE_TYPE_ARGUMENTS);
    }
  }

  Future<void> _addFix_removeUnnecessaryCast() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (coveredNode is! AsExpression) {
      return;
    }
    AsExpression asExpression = coveredNode as AsExpression;
    Expression expression = asExpression.expression;
    int expressionPrecedence = getExpressionPrecedence(expression);
    // remove 'as T' from 'e as T'
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addDeletion(range.endEnd(expression, asExpression));
      _removeEnclosingParentheses(builder, asExpression, expressionPrecedence);
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.REMOVE_UNNECESSARY_CAST);
  }

  Future<void> _addFix_removeUnusedCatchClause() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is SimpleIdentifier) {
      AstNode catchClause = node.parent;
      if (catchClause is CatchClause &&
          catchClause.exceptionParameter == node) {
        DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
          builder.addDeletion(
              range.startStart(catchClause.catchKeyword, catchClause.body));
        });
        _addFixFromBuilder(
            changeBuilder, DartFixKind.REMOVE_UNUSED_CATCH_CLAUSE);
      }
    }
  }

  Future<void> _addFix_removeUnusedCatchStack() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is SimpleIdentifier) {
      AstNode catchClause = node.parent;
      if (catchClause is CatchClause &&
          catchClause.stackTraceParameter == node &&
          catchClause.exceptionParameter != null) {
        DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
          builder
              .addDeletion(range.endEnd(catchClause.exceptionParameter, node));
        });
        _addFixFromBuilder(
            changeBuilder, DartFixKind.REMOVE_UNUSED_CATCH_STACK);
      }
    }
  }

  Future<void> _addFix_removeUnusedImport() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    // prepare ImportDirective
    ImportDirective importDirective =
        node.getAncestor((node) => node is ImportDirective);
    if (importDirective == null) {
      return;
    }
    // remove the whole line with import
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addDeletion(utils.getLinesRange(range.node(importDirective)));
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.REMOVE_UNUSED_IMPORT);
  }

  Future<void> _addFix_renameToCamelCase() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is! SimpleIdentifier) {
      return;
    }
    SimpleIdentifier identifier = this.node;

    // Prepare the new name.
    List<String> words = identifier.name.split('_');
    if (words.length < 2) {
      return;
    }
    var newName = words.first + words.skip(1).map((w) => capitalize(w)).join();

    // Find references to the identifier.
    List<SimpleIdentifier> references;
    Element element = identifier.staticElement;
    if (element is LocalVariableElement) {
      AstNode root = node.getAncestor((node) => node is Block);
      references = findLocalElementReferences(root, element);
    } else if (element is ParameterElement) {
      if (!element.isNamed) {
        AstNode root = node.getAncestor((node) =>
            node.parent is ClassOrMixinDeclaration ||
            node.parent is CompilationUnit);
        references = findLocalElementReferences(root, element);
      }
    }
    if (references == null) {
      return;
    }

    // Compute the change.
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      for (var reference in references) {
        builder.addSimpleReplacement(range.node(reference), newName);
      }
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.RENAME_TO_CAMEL_CASE,
        args: [newName]);
  }

  Future<void> _addFix_replaceFinalWithConst() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is VariableDeclarationList) {
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addSimpleReplacement(
            range.token((node as VariableDeclarationList).keyword), 'const');
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.REPLACE_FINAL_WITH_CONST);
    }
  }

  Future<void> _addFix_replaceVarWithDynamic() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addSimpleReplacement(range.error(error), 'dynamic');
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.REPLACE_VAR_WITH_DYNAMIC);
  }

  Future<void> _addFix_replaceWithConditionalAssignment() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    IfStatement ifStatement = node is IfStatement
        ? node
        : node.getAncestor((node) => node is IfStatement);
    if (ifStatement == null) {
      return;
    }
    var thenStatement = ifStatement.thenStatement;
    Statement uniqueStatement(Statement statement) {
      if (statement is Block) {
        return uniqueStatement(statement.statements.first);
      }
      return statement;
    }

    thenStatement = uniqueStatement(thenStatement);
    if (thenStatement is ExpressionStatement) {
      final expression = thenStatement.expression.unParenthesized;
      if (expression is AssignmentExpression) {
        DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
          builder.addReplacement(range.node(ifStatement),
              (DartEditBuilder builder) {
            builder.write(utils.getNodeText(expression.leftHandSide));
            builder.write(' ??= ');
            builder.write(utils.getNodeText(expression.rightHandSide));
            builder.write(';');
          });
        });
        _addFixFromBuilder(
            changeBuilder, DartFixKind.REPLACE_WITH_CONDITIONAL_ASSIGNMENT);
      }
    }
  }

  Future<void> _addFix_replaceWithConstInstanceCreation() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (coveredNode is InstanceCreationExpression) {
      var instanceCreation = coveredNode as InstanceCreationExpression;
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        if (instanceCreation.keyword == null) {
          builder.addSimpleInsertion(
              instanceCreation.constructorName.offset, 'const');
        } else {
          builder.addSimpleReplacement(
              range.token(instanceCreation.keyword), 'const');
        }
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.USE_CONST);
    }
  }

  Future<void> _addFix_replaceWithIdentifier() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    final FunctionTypedFormalParameter functionTyped =
        node.getAncestor((node) => node is FunctionTypedFormalParameter);
    if (functionTyped != null) {
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addSimpleReplacement(range.node(functionTyped),
            utils.getNodeText(functionTyped.identifier));
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.REPLACE_WITH_IDENTIFIER);
    } else {
      await _addFix_removeTypeAnnotation();
    }
  }

  Future<void> _addFix_replaceWithLiteral() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    final InstanceCreationExpression instanceCreation =
        node.getAncestor((node) => node is InstanceCreationExpression);
    final InterfaceType type = instanceCreation.staticType;
    final generics = instanceCreation.constructorName.type.typeArguments;
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addReplacement(range.node(instanceCreation),
          (DartEditBuilder builder) {
        if (generics != null) {
          builder.write(utils.getNodeText(generics));
        }
        if (type.name == 'List') {
          builder.write('[]');
        } else {
          builder.write('{}');
        }
      });
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.REPLACE_WITH_LITERAL);
  }

  Future<void> _addFix_replaceWithTearOff() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    FunctionExpression ancestor =
        node.getAncestor((a) => a is FunctionExpression);
    if (ancestor == null) {
      return;
    }
    Future<void> addFixOfExpression(InvocationExpression expression) async {
      // TODO(brianwilkerson) Determine whether this await is necessary.
      await null;
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addReplacement(range.node(ancestor), (DartEditBuilder builder) {
          if (expression is MethodInvocation && expression.target != null) {
            builder.write(utils.getNodeText(expression.target));
            builder.write('.');
          }
          builder.write(utils.getNodeText(expression.function));
        });
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.REPLACE_WITH_TEAR_OFF);
    }

    final body = ancestor.body;
    if (body is ExpressionFunctionBody) {
      final expression = body.expression;
      await addFixOfExpression(expression.unParenthesized);
    } else if (body is BlockFunctionBody) {
      final statement = body.block.statements.first;
      if (statement is ExpressionStatement) {
        final expression = statement.expression;
        await addFixOfExpression(expression.unParenthesized);
      } else if (statement is ReturnStatement) {
        final expression = statement.expression;
        await addFixOfExpression(expression.unParenthesized);
      }
    }
  }

  Future<void> _addFix_undefinedClass_useSimilar() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    AstNode node = this.node;
    // Prepare the optional import prefix name.
    String prefixName = null;
    if (node is SimpleIdentifier && node.staticElement is PrefixElement) {
      AstNode parent = node.parent;
      if (parent is PrefixedIdentifier &&
          parent.prefix == node &&
          parent.parent is TypeName) {
        prefixName = (node as SimpleIdentifier).name;
        node = parent.identifier;
      }
    }
    // Process if looks like a type.
    if (_mayBeTypeIdentifier(node)) {
      // Prepare for selecting the closest element.
      String name = (node as SimpleIdentifier).name;
      _ClosestElementFinder finder = new _ClosestElementFinder(
          name,
          (Element element) => element is ClassElement,
          MAX_LEVENSHTEIN_DISTANCE);
      // Check elements of this library.
      if (prefixName == null) {
        for (CompilationUnitElement unit in unitLibraryElement.units) {
          finder._updateList(unit.types);
        }
      }
      // Check elements from imports.
      for (ImportElement importElement in unitLibraryElement.imports) {
        if (importElement.prefix?.name == prefixName) {
          Map<String, Element> namespace = getImportNamespace(importElement);
          finder._updateList(namespace.values);
        }
      }
      // If we have a close enough element, suggest to use it.
      if (finder._element != null) {
        String closestName = finder._element.name;
        if (closestName != null) {
          DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
          await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
            builder.addSimpleReplacement(range.node(node), closestName);
          });
          _addFixFromBuilder(changeBuilder, DartFixKind.CHANGE_TO,
              args: [closestName]);
        }
      }
    }
  }

  Future<void> _addFix_undefinedClassAccessor_useSimilar() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    AstNode node = this.node;
    if (node is SimpleIdentifier) {
      // prepare target
      Expression target = null;
      if (node.parent is PrefixedIdentifier) {
        PrefixedIdentifier invocation = node.parent as PrefixedIdentifier;
        target = invocation.prefix;
      }
      // find getter
      if (node.inGetterContext()) {
        await _addFix_undefinedClassMember_useSimilar(target,
            (Element element) {
          return element is PropertyAccessorElement && element.isGetter ||
              element is FieldElement && element.getter != null;
        });
      }
      // find setter
      if (node.inSetterContext()) {
        await _addFix_undefinedClassMember_useSimilar(target,
            (Element element) {
          return element is PropertyAccessorElement && element.isSetter ||
              element is FieldElement && element.setter != null;
        });
      }
    }
  }

  Future<void> _addFix_undefinedClassMember_useSimilar(
      Expression target, ElementPredicate predicate) async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is SimpleIdentifier) {
      String name = (node as SimpleIdentifier).name;
      _ClosestElementFinder finder =
          new _ClosestElementFinder(name, predicate, MAX_LEVENSHTEIN_DISTANCE);
      // unqualified invocation
      if (target == null) {
        ClassDeclaration clazz =
            node.getAncestor((node) => node is ClassDeclaration);
        if (clazz != null) {
          ClassElement classElement = clazz.declaredElement;
          _updateFinderWithClassMembers(finder, classElement);
        }
      } else {
        DartType type = target.staticType;
        if (type is InterfaceType) {
          ClassElement classElement = type.element;
          _updateFinderWithClassMembers(finder, classElement);
        }
      }
      // if we have close enough element, suggest to use it
      if (finder._element != null) {
        String closestName = finder._element.name;
        DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
          builder.addSimpleReplacement(range.node(node), closestName);
        });
        _addFixFromBuilder(changeBuilder, DartFixKind.CHANGE_TO,
            args: [closestName]);
      }
    }
  }

  Future<void> _addFix_undefinedFunction_create() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    // should be the name of the invocation
    if (node is SimpleIdentifier && node.parent is MethodInvocation) {
    } else {
      return;
    }
    String name = (node as SimpleIdentifier).name;
    MethodInvocation invocation = node.parent as MethodInvocation;
    // function invocation has no target
    Expression target = invocation.realTarget;
    if (target != null) {
      return;
    }
    // prepare environment
    int insertOffset;
    String sourcePrefix;
    AstNode enclosingMember =
        node.getAncestor((node) => node is CompilationUnitMember);
    insertOffset = enclosingMember.end;
    sourcePrefix = '$eol$eol';
    utils.targetClassElement = null;
    // build method source
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      builder.addInsertion(insertOffset, (DartEditBuilder builder) {
        builder.write(sourcePrefix);
        // append return type
        {
          DartType type = _inferUndefinedExpressionType(invocation);
          if (builder.writeType(type, groupName: 'RETURN_TYPE')) {
            builder.write(' ');
          }
        }
        // append name
        builder.addLinkedEdit('NAME', (DartLinkedEditBuilder builder) {
          builder.write(name);
        });
        builder.write('(');
        builder.writeParametersMatchingArguments(invocation.argumentList);
        builder.write(') {$eol}');
      });
      builder.addLinkedPosition(range.node(node), 'NAME');
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_FUNCTION,
        args: [name]);
  }

  Future<void> _addFix_undefinedFunction_useSimilar() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    AstNode node = this.node;
    if (node is SimpleIdentifier) {
      // Prepare the optional import prefix name.
      String prefixName = null;
      {
        AstNode invocation = node.parent;
        if (invocation is MethodInvocation && invocation.methodName == node) {
          Expression target = invocation.target;
          if (target is SimpleIdentifier &&
              target.staticElement is PrefixElement) {
            prefixName = target.name;
          }
        }
      }
      // Prepare for selecting the closest element.
      _ClosestElementFinder finder = new _ClosestElementFinder(
          node.name,
          (Element element) => element is FunctionElement,
          MAX_LEVENSHTEIN_DISTANCE);
      // Check to this library units.
      if (prefixName == null) {
        for (CompilationUnitElement unit in unitLibraryElement.units) {
          finder._updateList(unit.functions);
        }
      }
      // Check unprefixed imports.
      for (ImportElement importElement in unitLibraryElement.imports) {
        if (importElement.prefix?.name == prefixName) {
          Map<String, Element> namespace = getImportNamespace(importElement);
          finder._updateList(namespace.values);
        }
      }
      // If we have a close enough element, suggest to use it.
      if (finder._element != null) {
        String closestName = finder._element.name;
        DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
          builder.addSimpleReplacement(range.node(node), closestName);
        });
        _addFixFromBuilder(changeBuilder, DartFixKind.CHANGE_TO,
            args: [closestName]);
      }
    }
  }

  Future<void> _addFix_undefinedMethod_create() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is SimpleIdentifier && node.parent is MethodInvocation) {
      String name = (node as SimpleIdentifier).name;
      MethodInvocation invocation = node.parent as MethodInvocation;
      // prepare environment
      Element targetElement;
      bool staticModifier = false;

      ClassDeclaration targetClassNode;
      Expression target = invocation.realTarget;
      if (target == null) {
        targetElement = unitElement;
        ClassMember enclosingMember =
            node.getAncestor((node) => node is ClassMember);
        if (enclosingMember == null) {
          // If the undefined identifier isn't inside a class member, then it
          // doesn't make sense to create a method.
          return;
        }
        targetClassNode = enclosingMember.parent;
        utils.targetClassElement = targetClassNode.declaredElement;
        staticModifier = _inStaticContext();
      } else {
        // prepare target interface type
        DartType targetType = target.staticType;
        if (targetType is! InterfaceType) {
          return;
        }
        ClassElement targetClassElement = targetType.element as ClassElement;
        if (targetClassElement.librarySource.isInSystemLibrary) {
          return;
        }
        targetElement = targetClassElement;
        // prepare target ClassDeclaration
        AstNode targetTypeNode = getParsedClassElementNode(targetClassElement);
        if (targetTypeNode is! ClassDeclaration) {
          return;
        }
        targetClassNode = targetTypeNode;
        // maybe static
        if (target is Identifier) {
          staticModifier =
              resolutionMap.staticElementForIdentifier(target).kind ==
                  ElementKind.CLASS;
        }
        // use different utils
        CompilationUnitElement targetUnitElement =
            getCompilationUnitElement(targetClassElement);
        CompilationUnit targetUnit = getParsedUnit(targetUnitElement);
        utils = new CorrectionUtils(targetUnit);
      }
      ClassMemberLocation targetLocation =
          utils.prepareNewMethodLocation(targetClassNode);
      String targetFile = targetElement.source.fullName;
      // build method source
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(targetFile,
          (DartFileEditBuilder builder) {
        builder.addInsertion(targetLocation.offset, (DartEditBuilder builder) {
          builder.write(targetLocation.prefix);
          // maybe "static"
          if (staticModifier) {
            builder.write('static ');
          }
          // append return type
          {
            DartType type = _inferUndefinedExpressionType(invocation);
            if (builder.writeType(type, groupName: 'RETURN_TYPE')) {
              builder.write(' ');
            }
          }
          // append name
          builder.addLinkedEdit('NAME', (DartLinkedEditBuilder builder) {
            builder.write(name);
          });
          builder.write('(');
          builder.writeParametersMatchingArguments(invocation.argumentList);
          builder.write(') {}');
          builder.write(targetLocation.suffix);
        });
        if (targetFile == file) {
          builder.addLinkedPosition(range.node(node), 'NAME');
        }
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_METHOD,
          args: [name]);
    }
  }

  Future<void> _addFix_undefinedMethod_useSimilar() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node.parent is MethodInvocation) {
      MethodInvocation invocation = node.parent as MethodInvocation;
      await _addFix_undefinedClassMember_useSimilar(invocation.realTarget,
          (Element element) => element is MethodElement && !element.isOperator);
    }
  }

  Future<void> _addFix_undefinedMethodWithContructor() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is SimpleIdentifier && node.parent is MethodInvocation) {
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        builder.addSimpleInsertion(node.parent.offset, 'new ');
      });
      _addFixFromBuilder(
          changeBuilder, DartFixKind.INVOKE_CONSTRUCTOR_USING_NEW);
      // TODO(brianwilkerson) Figure out whether the constructor is a `const`
      // constructor and all of the parameters are constant expressions, and
      // suggest inserting 'const ' if so.
    }
  }

  /**
   * Here we handle cases when a constructors does not initialize all of the
   * final fields.
   */
  Future<void> _addFix_updateConstructor_forUninitializedFinalFields() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is! SimpleIdentifier || node.parent is! ConstructorDeclaration) {
      return;
    }
    ConstructorDeclaration constructor = node.parent;
    List<FormalParameter> parameters = constructor.parameters.parameters;

    ClassDeclaration classNode = constructor.parent;
    InterfaceType superType = classNode.declaredElement.supertype;

    // Compute uninitialized final fields.
    List<FieldElement> fields =
        ErrorVerifier.computeNotInitializedFields(constructor);
    fields.retainWhere((FieldElement field) => field.isFinal);

    // Prepare new parameters code.
    fields.sort((a, b) => a.nameOffset - b.nameOffset);
    String fieldParametersCode =
        fields.map((field) => 'this.${field.name}').join(', ');

    // Specialize for Flutter widgets.
    if (flutter.isExactlyStatelessWidgetType(superType) ||
        flutter.isExactlyStatefulWidgetType(superType)) {
      if (parameters.isNotEmpty && parameters.last.isNamed) {
        DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
          builder.addSimpleInsertion(
              parameters.last.end, ', $fieldParametersCode');
        });
        _addFixFromBuilder(
            changeBuilder, DartFixKind.ADD_FIELD_FORMAL_PARAMETERS);
        return;
      }
    }

    // Prepare the last required parameter.
    FormalParameter lastRequiredParameter;
    for (FormalParameter parameter in parameters) {
      if (parameter.isRequired) {
        lastRequiredParameter = parameter;
      }
    }

    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
      // append new field formal initializers
      if (lastRequiredParameter != null) {
        builder.addSimpleInsertion(
            lastRequiredParameter.end, ', $fieldParametersCode');
      } else {
        int offset = constructor.parameters.leftParenthesis.end;
        if (parameters.isNotEmpty) {
          fieldParametersCode += ', ';
        }
        builder.addSimpleInsertion(offset, fieldParametersCode);
      }
    });
    _addFixFromBuilder(changeBuilder, DartFixKind.ADD_FIELD_FORMAL_PARAMETERS);
  }

  Future<void> _addFix_useEffectiveIntegerDivision() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    for (AstNode n = node; n != null; n = n.parent) {
      if (n is MethodInvocation &&
          n.offset == errorOffset &&
          n.length == errorLength) {
        Expression target = (n as MethodInvocation).target.unParenthesized;
        DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
        await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
          // replace "/" with "~/"
          BinaryExpression binary = target as BinaryExpression;
          builder.addSimpleReplacement(range.token(binary.operator), '~/');
          // remove everything before and after
          builder.addDeletion(range.startStart(n, binary.leftOperand));
          builder.addDeletion(range.endEnd(binary.rightOperand, n));
        });
        _addFixFromBuilder(
            changeBuilder, DartFixKind.USE_EFFECTIVE_INTEGER_DIVISION);
        // done
        break;
      }
    }
  }

  /**
   * Adds a fix that replaces [target] with a reference to the class declaring
   * the given [element].
   */
  Future<void> _addFix_useStaticAccess(AstNode target, Element element) async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    Element declaringElement = element.enclosingElement;
    if (declaringElement is ClassElement) {
      DartType declaringType = declaringElement.type;
      DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
      await changeBuilder.addFileEdit(file, (DartFileEditBuilder builder) {
        // replace "target" with class name
        builder.addReplacement(range.node(target), (DartEditBuilder builder) {
          builder.writeType(declaringType);
        });
      });
      _addFixFromBuilder(changeBuilder, DartFixKind.CHANGE_TO_STATIC_ACCESS,
          args: [declaringType]);
    }
  }

  Future<void> _addFix_useStaticAccess_method() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is SimpleIdentifier && node.parent is MethodInvocation) {
      MethodInvocation invocation = node.parent as MethodInvocation;
      if (invocation.methodName == node) {
        Expression target = invocation.target;
        Element invokedElement = invocation.methodName.staticElement;
        await _addFix_useStaticAccess(target, invokedElement);
      }
    }
  }

  Future<void> _addFix_useStaticAccess_property() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    if (node is SimpleIdentifier && node.parent is PrefixedIdentifier) {
      PrefixedIdentifier prefixed = node.parent as PrefixedIdentifier;
      if (prefixed.identifier == node) {
        Expression target = prefixed.prefix;
        Element invokedElement = prefixed.identifier.staticElement;
        await _addFix_useStaticAccess(target, invokedElement);
      }
    }
  }

  void _addFixFromBuilder(DartChangeBuilder builder, FixKind kind,
      {List args: null, bool importsOnly: false}) {
    SourceChange change = builder.sourceChange;
    if (change.edits.isEmpty && !importsOnly) {
      return;
    }
    change.message = formatList(kind.message, args);
    fixes.add(new Fix(kind, change));
  }

  /**
   * Prepares proposal for creating function corresponding to the given
   * [FunctionType].
   */
  Future<DartChangeBuilder> _addProposal_createFunction(
      FunctionType functionType,
      String name,
      Source targetSource,
      int insertOffset,
      bool isStatic,
      String prefix,
      String sourcePrefix,
      String sourceSuffix,
      Element target) async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    // build method source
    String targetFile = targetSource.fullName;
    DartChangeBuilder changeBuilder = new DartChangeBuilder(session);
    await changeBuilder.addFileEdit(targetFile, (DartFileEditBuilder builder) {
      builder.addInsertion(insertOffset, (DartEditBuilder builder) {
        builder.write(sourcePrefix);
        builder.write(prefix);
        // may be static
        if (isStatic) {
          builder.write('static ');
        }
        // append return type
        if (builder.writeType(functionType.returnType,
            groupName: 'RETURN_TYPE')) {
          builder.write(' ');
        }
        // append name
        builder.addLinkedEdit('NAME', (DartLinkedEditBuilder builder) {
          builder.write(name);
        });
        // append parameters
        builder.write('(');
        List<ParameterElement> parameters = functionType.parameters;
        for (int i = 0; i < parameters.length; i++) {
          ParameterElement parameter = parameters[i];
          // append separator
          if (i != 0) {
            builder.write(', ');
          }
          // append type name
          DartType type = parameter.type;
          if (!type.isDynamic) {
            builder.addLinkedEdit('TYPE$i',
                (DartLinkedEditBuilder innerBuilder) {
              builder.writeType(type);
              innerBuilder.addSuperTypesAsSuggestions(type);
            });
            builder.write(' ');
          }
          // append parameter name
          builder.addLinkedEdit('ARG$i', (DartLinkedEditBuilder builder) {
            builder.write(parameter.displayName);
          });
        }
        builder.write(')');
        // close method
        builder.write(' {$eol$prefix}');
        builder.write(sourceSuffix);
      });
      if (targetSource == unitSource) {
        builder.addLinkedPosition(range.node(node), 'NAME');
      }
    });
    return changeBuilder;
  }

  /**
   * Adds proposal for creating method corresponding to the given [FunctionType] in the given
   * [ClassElement].
   */
  Future<void> _addProposal_createFunction_function(
      FunctionType functionType) async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    String name = (node as SimpleIdentifier).name;
    // prepare environment
    int insertOffset = unit.end;
    // prepare prefix
    String prefix = '';
    String sourcePrefix = '$eol';
    String sourceSuffix = eol;
    DartChangeBuilder changeBuilder = await _addProposal_createFunction(
        functionType,
        name,
        unitSource,
        insertOffset,
        false,
        prefix,
        sourcePrefix,
        sourceSuffix,
        unitElement);
    _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_FUNCTION,
        args: [name]);
  }

  /**
   * Adds proposal for creating method corresponding to the given [FunctionType] in the given
   * [ClassElement].
   */
  Future<void> _addProposal_createFunction_method(
      ClassElement targetClassElement, FunctionType functionType) async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    String name = (node as SimpleIdentifier).name;
    // prepare environment
    Source targetSource = targetClassElement.source;
    // prepare insert offset
    ClassDeclaration targetClassNode =
        getParsedClassElementNode(targetClassElement);
    int insertOffset = targetClassNode.end - 1;
    // prepare prefix
    String prefix = '  ';
    String sourcePrefix;
    if (targetClassNode.members.isEmpty) {
      sourcePrefix = '';
    } else {
      sourcePrefix = eol;
    }
    String sourceSuffix = eol;
    DartChangeBuilder changeBuilder = await _addProposal_createFunction(
        functionType,
        name,
        targetSource,
        insertOffset,
        _inStaticContext(),
        prefix,
        sourcePrefix,
        sourceSuffix,
        targetClassElement);
    _addFixFromBuilder(changeBuilder, DartFixKind.CREATE_METHOD, args: [name]);
  }

  /**
   * Computes the name of the library at the given [path].
   * See https://www.dartlang.org/articles/style-guide/#names for conventions.
   */
  String _computeLibraryName(String path) {
    Context pathContext = resourceProvider.pathContext;
    String packageFolder = _computePackageFolder(path);
    if (packageFolder == null) {
      return pathContext.basenameWithoutExtension(path);
    }
    String packageName = pathContext.basename(packageFolder);
    String relPath = pathContext.relative(path, from: packageFolder);
    List<String> relPathParts = pathContext.split(relPath);
    if (relPathParts.isNotEmpty) {
      if (relPathParts[0].toLowerCase() == 'lib') {
        relPathParts.removeAt(0);
      }
      if (relPathParts.isNotEmpty) {
        String nameWithoutExt = pathContext.withoutExtension(relPathParts.last);
        relPathParts[relPathParts.length - 1] = nameWithoutExt;
      }
    }
    return packageName + '.' + relPathParts.join('.');
  }

  /**
   * Returns the path of the folder which contains the given [path].
   */
  String _computePackageFolder(String path) {
    Context pathContext = resourceProvider.pathContext;
    String pubspecFolder = dirname(path);
    while (true) {
      if (resourceProvider
          .getResource(pathContext.join(pubspecFolder, 'pubspec.yaml'))
          .exists) {
        return pubspecFolder;
      }
      String pubspecFolderNew = pathContext.dirname(pubspecFolder);
      if (pubspecFolderNew == pubspecFolder) {
        return null;
      }
      pubspecFolder = pubspecFolderNew;
    }
  }

  /**
   * Return the string to display as the name of the given constructor in a
   * proposal name.
   */
  String _getConstructorProposalName(ConstructorElement constructor) {
    StringBuffer buffer = new StringBuffer();
    buffer.write('super');
    String constructorName = constructor.displayName;
    if (!constructorName.isEmpty) {
      buffer.write('.');
      buffer.write(constructorName);
    }
    buffer.write('(...)');
    return buffer.toString();
  }

  /**
   * Returns the [DartType] with given name from the `dart:core` library.
   */
  DartType _getCoreType(String name) {
    List<LibraryElement> libraries = unitLibraryElement.importedLibraries;
    for (LibraryElement library in libraries) {
      if (library.isDartCore) {
        ClassElement classElement = library.getType(name);
        if (classElement != null) {
          return classElement.type;
        }
        return null;
      }
    }
    return null;
  }

  /**
   * Return the correction utilities that should be used when creating an edit
   * in the compilation unit containing the given [node].
   */
  CorrectionUtils _getUtilsFor(AstNode node) {
    CompilationUnit targetUnit =
        node.getAncestor((node) => node is CompilationUnit);
    CompilationUnitElement targetUnitElement = targetUnit?.declaredElement;
    CorrectionUtils realUtils = utils;
    if (targetUnitElement != utils.unit.declaredElement) {
      realUtils = new CorrectionUtils(targetUnit);
      ClassDeclaration targetClass =
          node.getAncestor((node) => node is ClassDeclaration);
      if (targetClass != null) {
        realUtils.targetClassElement = targetClass.declaredElement;
      }
    }
    return realUtils;
  }

  /**
   * Returns an expected [DartType] of [expression], may be `null` if cannot be
   * inferred.
   */
  DartType _inferUndefinedExpressionType(Expression expression) {
    AstNode parent = expression.parent;
    // myFunction();
    if (parent is ExpressionStatement) {
      if (expression is MethodInvocation) {
        return VoidTypeImpl.instance;
      }
    }
    // return myFunction();
    if (parent is ReturnStatement) {
      ExecutableElement executable = getEnclosingExecutableElement(expression);
      return executable?.returnType;
    }
    // int v = myFunction();
    if (parent is VariableDeclaration) {
      VariableDeclaration variableDeclaration = parent;
      if (variableDeclaration.initializer == expression) {
        VariableElement variableElement = variableDeclaration.declaredElement;
        if (variableElement != null) {
          return variableElement.type;
        }
      }
    }
    // myField = 42;
    if (parent is AssignmentExpression) {
      AssignmentExpression assignment = parent;
      if (assignment.leftHandSide == expression) {
        Expression rhs = assignment.rightHandSide;
        if (rhs != null) {
          return rhs.staticType;
        }
      }
    }
    // v = myFunction();
    if (parent is AssignmentExpression) {
      AssignmentExpression assignment = parent;
      if (assignment.rightHandSide == expression) {
        if (assignment.operator.type == TokenType.EQ) {
          // v = myFunction();
          Expression lhs = assignment.leftHandSide;
          if (lhs != null) {
            return lhs.staticType;
          }
        } else {
          // v += myFunction();
          MethodElement method = assignment.staticElement;
          if (method != null) {
            List<ParameterElement> parameters = method.parameters;
            if (parameters.length == 1) {
              return parameters[0].type;
            }
          }
        }
      }
    }
    // v + myFunction();
    if (parent is BinaryExpression) {
      BinaryExpression binary = parent;
      MethodElement method = binary.staticElement;
      if (method != null) {
        if (binary.rightOperand == expression) {
          List<ParameterElement> parameters = method.parameters;
          return parameters.length == 1 ? parameters[0].type : null;
        }
      }
    }
    // foo( myFunction() );
    if (parent is ArgumentList) {
      ParameterElement parameter = expression.staticParameterElement;
      return parameter?.type;
    }
    // bool
    {
      // assert( myFunction() );
      if (parent is AssertStatement) {
        AssertStatement statement = parent;
        if (statement.condition == expression) {
          return coreTypeBool;
        }
      }
      // if ( myFunction() ) {}
      if (parent is IfStatement) {
        IfStatement statement = parent;
        if (statement.condition == expression) {
          return coreTypeBool;
        }
      }
      // while ( myFunction() ) {}
      if (parent is WhileStatement) {
        WhileStatement statement = parent;
        if (statement.condition == expression) {
          return coreTypeBool;
        }
      }
      // do {} while ( myFunction() );
      if (parent is DoStatement) {
        DoStatement statement = parent;
        if (statement.condition == expression) {
          return coreTypeBool;
        }
      }
      // !myFunction()
      if (parent is PrefixExpression) {
        PrefixExpression prefixExpression = parent;
        if (prefixExpression.operator.type == TokenType.BANG) {
          return coreTypeBool;
        }
      }
      // binary expression '&&' or '||'
      if (parent is BinaryExpression) {
        BinaryExpression binaryExpression = parent;
        TokenType operatorType = binaryExpression.operator.type;
        if (operatorType == TokenType.AMPERSAND_AMPERSAND ||
            operatorType == TokenType.BAR_BAR) {
          return coreTypeBool;
        }
      }
    }
    // we don't know
    return null;
  }

  /**
   * Returns `true` if [node] is in static context.
   */
  bool _inStaticContext() {
    // constructor initializer cannot reference "this"
    if (node.getAncestor((node) => node is ConstructorInitializer) != null) {
      return true;
    }
    // field initializer cannot reference "this"
    if (node.getAncestor((node) => node is FieldDeclaration) != null) {
      return true;
    }
    // static method
    MethodDeclaration method = node.getAncestor((node) {
      return node is MethodDeclaration;
    });
    return method != null && method.isStatic;
  }

  bool _isAwaitNode() {
    AstNode node = this.node;
    return node is SimpleIdentifier && node.name == 'await';
  }

  bool _isCastMethodElement(MethodElement method) {
    if (method.name != 'cast') {
      return false;
    }
    ClassElement definingClass = method.enclosingElement;
    return _isDartCoreIterableElement(definingClass) ||
        _isDartCoreListElement(definingClass) ||
        _isDartCoreMapElement(definingClass) ||
        _isDartCoreSetElement(definingClass);
  }

  bool _isCastMethodInvocation(Expression expression) {
    if (expression is MethodInvocation) {
      Element element = expression.methodName.staticElement;
      return element is MethodElement && _isCastMethodElement(element);
    }
    return false;
  }

  bool _isDartCoreIterable(DartType type) =>
      type is InterfaceType && _isDartCoreIterableElement(type.element);

  bool _isDartCoreIterableElement(ClassElement element) =>
      element != null &&
      element.name == "Iterable" &&
      element.library.isDartCore;

  bool _isDartCoreList(DartType type) =>
      type is InterfaceType && _isDartCoreListElement(type.element);

  bool _isDartCoreListElement(ClassElement element) =>
      element != null && element.name == "List" && element.library.isDartCore;

  bool _isDartCoreMap(DartType type) =>
      type is InterfaceType && _isDartCoreMapElement(type.element);

  bool _isDartCoreMapElement(ClassElement element) =>
      element != null && element.name == "Map" && element.library.isDartCore;

  bool _isDartCoreSet(DartType type) =>
      type is InterfaceType && _isDartCoreSetElement(type.element);

  bool _isDartCoreSetElement(ClassElement element) =>
      element != null && element.name == "Set" && element.library.isDartCore;

  bool _isLibSrcPath(String path) {
    List<String> parts = resourceProvider.pathContext.split(path);
    for (int i = 0; i < parts.length - 2; i++) {
      if (parts[i] == 'lib' && parts[i + 1] == 'src') {
        return true;
      }
    }
    return false;
  }

  /**
   * Return `true` if the [source] can be imported into [unitLibraryFile].
   */
  bool _isSourceVisibleToLibrary(Source source) {
    String path = source.fullName;

    ContextRoot contextRoot = driver.contextRoot;
    if (contextRoot == null) {
      return true;
    }

    // We don't want to use private libraries of other packages.
    if (source.uri.isScheme('package') && _isLibSrcPath(path)) {
      return resourceProvider.pathContext.isWithin(contextRoot.root, path);
    }

    // We cannot use relative URIs to reference files outside of our package.
    if (source.uri.isScheme('file')) {
      return resourceProvider.pathContext.isWithin(contextRoot.root, path);
    }

    return true;
  }

  bool _isToListMethodElement(MethodElement method) {
    if (method.name != 'toList') {
      return false;
    }
    ClassElement definingClass = method.enclosingElement;
    return _isDartCoreIterableElement(definingClass) ||
        _isDartCoreListElement(definingClass);
  }

  bool _isToListMethodInvocation(Expression expression) {
    if (expression is MethodInvocation) {
      Element element = expression.methodName.staticElement;
      return element is MethodElement && _isToListMethodElement(element);
    }
    return false;
  }

  /**
   * Removes any [ParenthesizedExpression] enclosing [expr].
   *
   * [exprPrecedence] - the effective precedence of [expr].
   */
  void _removeEnclosingParentheses(
      DartFileEditBuilder builder, Expression expr, int exprPrecedence) {
    while (expr.parent is ParenthesizedExpression) {
      ParenthesizedExpression parenthesized =
          expr.parent as ParenthesizedExpression;
      if (getExpressionParentPrecedence(parenthesized) > exprPrecedence) {
        break;
      }
      builder.addDeletion(range.token(parenthesized.leftParenthesis));
      builder.addDeletion(range.token(parenthesized.rightParenthesis));
      expr = parenthesized;
    }
  }

  void _updateFinderWithClassMembers(
      _ClosestElementFinder finder, ClassElement clazz) {
    if (clazz != null) {
      List<Element> members = getMembers(clazz);
      finder._updateList(members);
    }
  }

  static bool _isNameOfType(String name) {
    if (name.isEmpty) {
      return false;
    }
    String firstLetter = name.substring(0, 1);
    if (firstLetter.toUpperCase() != firstLetter) {
      return false;
    }
    return true;
  }

  /**
   * Return `true` if the given [node] is in a location where an implicit
   * constructor invocation would be allowed.
   */
  static bool _mayBeImplicitConstructor(AstNode node) {
    if (node is SimpleIdentifier) {
      AstNode parent = node.parent;
      if (parent is MethodInvocation) {
        return parent.realTarget == null;
      }
    }
    return false;
  }

  /**
   * Returns `true` if [node] is a type name.
   */
  static bool _mayBeTypeIdentifier(AstNode node) {
    if (node is SimpleIdentifier) {
      AstNode parent = node.parent;
      if (parent is TypeName) {
        return true;
      }
      return _isNameOfType(node.name);
    }
    return false;
  }

  static String _replaceSourceIndent(
      String source, String indentOld, String indentNew) {
    return source.replaceAll(
        new RegExp('^$indentOld', multiLine: true), indentNew);
  }
}

/**
 * An enumeration of lint names.
 */
class LintNames {
  static const String always_require_non_null_named_parameters =
      'always_require_non_null_named_parameters';
  static const String annotate_overrides = 'annotate_overrides';
  static const String avoid_annotating_with_dynamic =
      'avoid_annotating_with_dynamic';
  static const String avoid_empty_else = 'avoid_empty_else';
  static const String avoid_init_to_null = 'avoid_init_to_null';
  static const String avoid_return_types_on_setters =
      'avoid_return_types_on_setters';
  static const String avoid_types_on_closure_parameters =
      'avoid_types_on_closure_parameters';
  static const String await_only_futures = 'await_only_futures';
  static const String empty_catches = 'empty_catches';
  static const String empty_constructor_bodies = 'empty_constructor_bodies';
  static const String empty_statements = 'empty_statements';
  static const String non_constant_identifier_names =
      'non_constant_identifier_names';
  static const String prefer_collection_literals = 'prefer_collection_literals';
  static const String prefer_conditional_assignment =
      'prefer_conditional_assignment';
  static const String prefer_const_declarations = 'prefer_const_declarations';
  static const String prefer_final_fields = 'prefer_final_fields';
  static const String prefer_final_locals = 'prefer_final_locals';
  static const String prefer_is_not_empty = 'prefer_is_not_empty';
  static const String type_init_formals = 'type_init_formals';
  static const String unnecessary_brace_in_string_interp =
      'unnecessary_brace_in_string_interp';
  static const String unnecessary_lambdas = 'unnecessary_lambdas';
  static const String unnecessary_override = 'unnecessary_override';
  static const String unnecessary_this = 'unnecessary_this';
}

/**
 * Helper for finding [Element] with name closest to the given.
 */
class _ClosestElementFinder {
  final String _targetName;
  final ElementPredicate _predicate;

  Element _element = null;
  int _distance;

  _ClosestElementFinder(this._targetName, this._predicate, this._distance);

  void _update(Element element) {
    if (_predicate(element)) {
      int memberDistance = levenshtein(element.name, _targetName, _distance);
      if (memberDistance < _distance) {
        _element = element;
        _distance = memberDistance;
      }
    }
  }

  void _updateList(Iterable<Element> elements) {
    for (Element element in elements) {
      _update(element);
    }
  }
}

/**
 * [ExecutableElement], its parameters, and operations on them.
 */
class _ExecutableParameters {
  final AstProvider astProvider;
  final ExecutableElement executable;

  final List<ParameterElement> required = [];
  final List<ParameterElement> optionalPositional = [];
  final List<ParameterElement> named = [];

  factory _ExecutableParameters(AstProvider astProvider, AstNode invocation) {
    Element element;
    if (invocation is InstanceCreationExpression) {
      element = invocation.staticElement;
    }
    if (invocation is MethodInvocation) {
      element = invocation.methodName.staticElement;
    }
    if (element is ExecutableElement) {
      return new _ExecutableParameters._(astProvider, element);
    } else {
      return null;
    }
  }

  _ExecutableParameters._(this.astProvider, this.executable) {
    for (var parameter in executable.parameters) {
      if (parameter.isNotOptional) {
        required.add(parameter);
      } else if (parameter.isOptionalPositional) {
        optionalPositional.add(parameter);
      } else if (parameter.isNamed) {
        named.add(parameter);
      }
    }
  }

  String get file => executable.source.fullName;

  /**
   * Return the [FormalParameterList] of the [executable], or `null` is cannot
   * be found.
   */
  Future<FormalParameterList> getParameterList() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    var name = await astProvider.getParsedNameForElement(executable);
    AstNode targetDeclaration = name?.parent;
    if (targetDeclaration is ConstructorDeclaration) {
      return targetDeclaration.parameters;
    } else if (targetDeclaration is FunctionDeclaration) {
      FunctionExpression function = targetDeclaration.functionExpression;
      return function.parameters;
    } else if (targetDeclaration is MethodDeclaration) {
      return targetDeclaration.parameters;
    }
    return null;
  }

  /**
   * Return the [FormalParameter] of the [element] in [FormalParameterList],
   * or `null` is cannot be found.
   */
  Future<FormalParameter> getParameterNode(ParameterElement element) async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    var name = await astProvider.getParsedNameForElement(element);
    for (AstNode node = name; node != null; node = node.parent) {
      if (node is FormalParameter && node.parent is FormalParameterList) {
        return node;
      }
    }
    return null;
  }
}
