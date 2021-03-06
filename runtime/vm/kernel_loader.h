// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#ifndef RUNTIME_VM_KERNEL_LOADER_H_
#define RUNTIME_VM_KERNEL_LOADER_H_

#if !defined(DART_PRECOMPILED_RUNTIME)

#include "vm/bit_vector.h"
#include "vm/compiler/frontend/kernel_translation_helper.h"
#include "vm/hash_map.h"
#include "vm/kernel.h"
#include "vm/object.h"
#include "vm/symbols.h"

namespace dart {
namespace kernel {

class KernelLoader;

class BuildingTranslationHelper : public TranslationHelper {
 public:
  BuildingTranslationHelper(KernelLoader* loader,
                            Thread* thread,
                            Heap::Space space)
      : TranslationHelper(thread, space), loader_(loader) {}
  virtual ~BuildingTranslationHelper() {}

  virtual RawLibrary* LookupLibraryByKernelLibrary(NameIndex library);
  virtual RawClass* LookupClassByKernelClass(NameIndex klass);

 private:
  KernelLoader* loader_;

  DISALLOW_COPY_AND_ASSIGN(BuildingTranslationHelper);
};

template <typename VmType>
class Mapping {
 public:
  bool Lookup(intptr_t canonical_name, VmType** handle) {
    typename MapType::Pair* pair = map_.LookupPair(canonical_name);
    if (pair != NULL) {
      *handle = pair->value;
      return true;
    }
    return false;
  }

  void Insert(intptr_t canonical_name, VmType* object) {
    map_.Insert(canonical_name, object);
  }

 private:
  typedef IntMap<VmType*> MapType;
  MapType map_;
};

class LibraryIndex {
 public:
  // |kernel_data| is the kernel data for one library alone.
  explicit LibraryIndex(const ExternalTypedData& kernel_data);

  intptr_t class_count() const { return class_count_; }
  intptr_t procedure_count() const { return procedure_count_; }

  intptr_t ClassOffset(intptr_t index) const {
    return reader_.ReadUInt32At(class_index_offset_ + index * 4);
  }

  intptr_t ProcedureOffset(intptr_t index) const {
    return reader_.ReadUInt32At(procedure_index_offset_ + index * 4);
  }

  intptr_t SizeOfClassAtOffset(intptr_t class_offset) const {
    for (intptr_t i = 0, offset = class_index_offset_; i < class_count_;
         ++i, offset += 4) {
      if (static_cast<intptr_t>(reader_.ReadUInt32At(offset)) == class_offset) {
        return reader_.ReadUInt32At(offset + 4) - class_offset;
      }
    }
    UNREACHABLE();
    return -1;
  }

 private:
  Reader reader_;
  intptr_t class_index_offset_;
  intptr_t class_count_;
  intptr_t procedure_index_offset_;
  intptr_t procedure_count_;

  DISALLOW_COPY_AND_ASSIGN(LibraryIndex);
};

class ClassIndex {
 public:
  // |class_offset| is the offset of class' kernel data in |buffer| of
  // size |size|. The size of the class' kernel data is |class_size|.
  ClassIndex(const uint8_t* buffer,
             intptr_t buffer_size,
             intptr_t class_offset,
             intptr_t class_size);

  // |class_offset| is the offset of class' kernel data in |kernel_data|.
  // The size of the class' kernel data is |class_size|.
  ClassIndex(const ExternalTypedData& kernel_data,
             intptr_t class_offset,
             intptr_t class_size);

  intptr_t procedure_count() const { return procedure_count_; }

  intptr_t ProcedureOffset(intptr_t index) const {
    return reader_.ReadUInt32At(procedure_index_offset_ + index * 4);
  }

 private:
  void Init(intptr_t class_offset, intptr_t class_size);

  Reader reader_;
  intptr_t procedure_count_;
  intptr_t procedure_index_offset_;

  DISALLOW_COPY_AND_ASSIGN(ClassIndex);
};

class KernelLoader : public ValueObject {
 public:
  explicit KernelLoader(Program* program);
  static Object& LoadEntireProgram(Program* program,
                                   bool process_pending_classes = true);

  // Returns the library containing the main procedure, null if there
  // was no main procedure, or a failure object if there was an error.
  RawObject* LoadProgram(bool process_pending_classes = true);

  // Returns the function which will evaluate the expression, or a failure
  // object if there was an error.
  RawObject* LoadExpressionEvaluationFunction(const String& library_url,
                                              const String& klass);

  // Finds all libraries that have been modified in this incremental
  // version of the kernel program file.
  static void FindModifiedLibraries(Program* program,
                                    Isolate* isolate,
                                    BitVector* modified_libs,
                                    bool force_reload,
                                    bool* is_empty_kernel);

  RawLibrary* LoadLibrary(intptr_t index);

  static void FinishLoading(const Class& klass);

  const Array& ReadConstantTable();

  // Check for the presence of a (possibly const) constructor for the
  // 'ExternalName' class. If found, returns the name parameter to the
  // constructor.
  RawString* DetectExternalNameCtor();

  // Check for the presence of a (possibly const) constructor for the 'pragma'
  // class. Returns whether it was found (no details about the type of pragma).
  bool DetectPragmaCtor();

  bool IsClassName(NameIndex name, const String& library, const String& klass);

  void AnnotateNativeProcedures(const Array& constant_table);
  void LoadNativeExtensionLibraries(const Array& constant_table);
  void EvaluateDelayedPragmas();

  void ReadVMAnnotations(intptr_t annotation_count,
                         String* native_name,
                         bool* is_potential_native,
                         bool* has_pragma_annotation);

  const String& DartSymbolPlain(StringIndex index) {
    return translation_helper_.DartSymbolPlain(index);
  }
  const String& DartSymbolObfuscate(StringIndex index) {
    return translation_helper_.DartSymbolObfuscate(index);
  }

  const String& LibraryUri(intptr_t library_index) {
    return translation_helper_.DartSymbolPlain(
        translation_helper_.CanonicalNameString(
            library_canonical_name(library_index)));
  }

  intptr_t library_offset(intptr_t index) {
    kernel::Reader reader(program_->kernel_data(),
                          program_->kernel_data_size());
    return reader.ReadFromIndexNoReset(reader.size(),
                                       LibraryCountFieldCountFromEnd + 1,
                                       program_->library_count() + 1, index);
  }

  NameIndex library_canonical_name(intptr_t index) {
    kernel::Reader reader(program_->kernel_data(),
                          program_->kernel_data_size());
    reader.set_offset(library_offset(index));

    // Start reading library.
    reader.ReadFlags();
    return reader.ReadCanonicalNameReference();
  }

  uint8_t CharacterAt(StringIndex string_index, intptr_t index);

 private:
  friend class BuildingTranslationHelper;

  KernelLoader(const Script& script,
               const ExternalTypedData& kernel_data,
               intptr_t data_program_offset);

  void InitializeFields();
  static void index_programs(kernel::Reader* reader,
                             GrowableArray<intptr_t>* subprogram_file_starts);
  void walk_incremental_kernel(BitVector* modified_libs,
                               bool* is_empty_program);

  void LoadPreliminaryClass(ClassHelper* class_helper,
                            intptr_t type_parameter_count);

  void ReadInferredType(const Field& field, intptr_t kernel_offset);
  void CheckForInitializer(const Field& field);

  void FixCoreLibraryScriptUri(const Library& library, const Script& script);

  void LoadClass(const Library& library,
                 const Class& toplevel_class,
                 intptr_t class_end,
                 Class* klass);

  void FinishClassLoading(const Class& klass,
                          const Library& library,
                          const Class& toplevel_class,
                          intptr_t class_offset,
                          const ClassIndex& class_index,
                          ClassHelper* class_helper);

  void LoadProcedure(const Library& library,
                     const Class& owner,
                     bool in_class,
                     intptr_t procedure_end);

  RawArray* MakeFunctionsArray();

  RawScript* LoadScriptAt(intptr_t index);

  // If klass's script is not the script at the uri index, return a PatchClass
  // for klass whose script corresponds to the uri index.
  // Otherwise return klass.
  const Object& ClassForScriptAt(const Class& klass, intptr_t source_uri_index);
  RawScript* ScriptAt(intptr_t source_uri_index,
                      StringIndex import_uri = StringIndex());

  void GenerateFieldAccessors(const Class& klass,
                              const Field& field,
                              FieldHelper* field_helper);

  void SetupFieldAccessorFunction(const Class& klass,
                                  const Function& function,
                                  const AbstractType& field_type);

  void LoadLibraryImportsAndExports(Library* library,
                                    const Class& toplevel_class);

  RawLibrary* LookupLibraryOrNull(NameIndex library);
  RawLibrary* LookupLibrary(NameIndex library);
  RawLibrary* LookupLibraryFromClass(NameIndex klass);
  RawClass* LookupClass(const Library& library, NameIndex klass);

  RawFunction::Kind GetFunctionType(ProcedureHelper::Kind procedure_kind);

  void EnsureExternalClassIsLookedUp() {
    if (external_name_class_.IsNull()) {
      ASSERT(external_name_field_.IsNull());
      const Library& internal_lib =
          Library::Handle(zone_, dart::Library::InternalLibrary());
      external_name_class_ = internal_lib.LookupClass(Symbols::ExternalName());
      external_name_field_ = external_name_class_.LookupField(Symbols::name());
    } else {
      ASSERT(!external_name_field_.IsNull());
    }
  }

  void EnsurePragmaClassIsLookedUp() {
    if (pragma_class_.IsNull()) {
      const Library& internal_lib =
          Library::Handle(zone_, dart::Library::InternalLibrary());
      pragma_class_ = internal_lib.LookupClass(Symbols::Pragma());
      ASSERT(!pragma_class_.IsNull());
    }
  }

  void EnsurePotentialNatives() {
    potential_natives_ = kernel_program_info_.potential_natives();
    if (potential_natives_.IsNull()) {
      // To avoid too many grows in this array, we'll set it's initial size to
      // something close to the actual number of potential native functions.
      potential_natives_ = GrowableObjectArray::New(100, Heap::kNew);
      kernel_program_info_.set_potential_natives(potential_natives_);
    }
  }

  void EnsurePotentialPragmaFunctions() {
    potential_pragma_functions_ =
        kernel_program_info_.potential_pragma_functions();
    if (potential_pragma_functions_.IsNull()) {
      // To avoid too many grows in this array, we'll set it's initial size to
      // something close to the actual number of potential native functions.
      potential_pragma_functions_ = GrowableObjectArray::New(100, Heap::kNew);
      kernel_program_info_.set_potential_pragma_functions(
          potential_pragma_functions_);
    }
  }

  void EnsurePotentialExtensionLibraries() {
    if (potential_extension_libraries_.IsNull()) {
      potential_extension_libraries_ = GrowableObjectArray::New();
    }
  }

  Program* program_;

  Thread* thread_;
  Zone* zone_;
  Isolate* isolate_;
  Array& patch_classes_;
  ActiveClass active_class_;
  // This is the offset of the current library within
  // the whole kernel program.
  intptr_t library_kernel_offset_;
  // This is the offset by which offsets, which are set relative
  // to their library's kernel data, have to be corrected.
  intptr_t correction_offset_;
  bool loading_native_wrappers_library_;

  NameIndex skip_vmservice_library_;

  ExternalTypedData& library_kernel_data_;
  KernelProgramInfo& kernel_program_info_;
  BuildingTranslationHelper translation_helper_;
  KernelReaderHelper helper_;
  TypeTranslator type_translator_;
  InferredTypeMetadataHelper inferred_type_metadata_helper_;

  Class& external_name_class_;
  Field& external_name_field_;
  GrowableObjectArray& potential_natives_;
  GrowableObjectArray& potential_pragma_functions_;
  GrowableObjectArray& potential_extension_libraries_;

  Class& pragma_class_;

  Smi& name_index_handle_;

  // We "re-use" the normal .dill file format for encoding compiled evaluation
  // expressions from the debugger.  This allows us to also reuse the normal
  // a) kernel loader b) flow graph building code.  The encoding is either one
  // of the following two options:
  //
  //   * Option a) The expression is evaluated inside an instance method call
  //               context:
  //
  //   Program:
  //   |> library "evaluate:source"
  //      |> class "#DebugClass"
  //         |> procedure ":Eval"
  //
  //   * Option b) The expression is evaluated outside an instance method call
  //               context:
  //
  //   Program:
  //   |> library "evaluate:source"
  //      |> procedure ":Eval"
  //
  // See
  //   * pkg/front_end/lib/src/fasta/incremental_compiler.dart:compileExpression
  //   * pkg/front_end/lib/src/fasta/kernel/utils.dart:serializeProcedure
  //
  Library& expression_evaluation_library_;
  Function& expression_evaluation_function_;

  GrowableArray<const Function*> functions_;
  GrowableArray<const Field*> fields_;

  DISALLOW_COPY_AND_ASSIGN(KernelLoader);
};

RawFunction* CreateFieldInitializerFunction(Thread* thread,
                                            Zone* zone,
                                            const Field& field);

ParsedFunction* ParseStaticFieldInitializer(Zone* zone, const Field& field);

}  // namespace kernel
}  // namespace dart

#endif  // !defined(DART_PRECOMPILED_RUNTIME)
#endif  // RUNTIME_VM_KERNEL_LOADER_H_
