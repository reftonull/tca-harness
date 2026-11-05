#if os(macOS)
import MacroTesting
import Testing
#if canImport(HarnessMacroImplementation)
import HarnessMacroImplementation
#else
import HarnessMacrosPlugin
#endif

@Suite(.macros(record: .failed, macros: ["HarnessFeature": HarnessFeatureMacro.self, "HarnessSchema": HarnessSchemaMacro.self, "HarnessOperation": MarkerMacro.self, "HarnessIgnore": MarkerMacro.self]))
struct HarnessMacroTests {
  @Test func featureAndChild() {
    assertMacro {
      """
      @HarnessFeature
      struct Parent {
        struct State {
          var child: Child.State?
        }
        enum Action {
          case openButtonTapped
          case child(Child.Action)
        }
      }
      """
    } expansion: {
      #"""
      struct Parent {
        struct State {
          var child: Child.State?
        }
        enum Action {
          case openButtonTapped
          case child(Child.Action)
        }

        @MainActor public static var harnessDescriptor: FeatureDescriptor<State, Action> {
          FeatureDescriptor<State, Action>("Parent", observation: { state in
              .object(["child": state.child.map {
                      Child.harnessDescriptor.snapshot($0)
                    } ?? .null])
            })
          .operation("openButtonTapped", label: "openButtonTapped", action: .openButtonTapped)
          .optional("child", state: \.child, action: \.child, descriptor: Child.harnessDescriptor)
        }
      }

      extension Parent: HarnessFeatureProvider {
      }
      """#
    }
  }

  @Test func recursiveInput() {
    assertMacro {
      """
      @HarnessSchema
      struct Input: Codable {
        var title: String
        var count: Int
        var tags: [String]
        var note: String?
      }
      """
    } expansion: {
      """
      struct Input: Codable {
        var title: String
        var count: Int
        var tags: [String]
        var note: String?

        public static var harnessSchema: HarnessJSONSchema {
          .object([
              "title": (String).harnessSchema,
              "count": (Int).harnessSchema,
              "tags": ([String]).harnessSchema,
              "note": (String?).harnessSchema
            ])
        }
      }

      extension Input: HarnessInput {
      }
      """
    }
  }

  @Test func unsupportedActionIsDiagnosed() {
    assertMacro {
      """
      @HarnessFeature
      struct Feature {
        struct State {}
        enum Action {
          case response(Result<String, Error>)
          case gesture(Double, Double)
        }
      }
      """
    } diagnostics: {
      """
      @HarnessFeature
      struct Feature {
        struct State {}
        enum Action {
          case response(Result<String, Error>)
               ┬──────────────────────────────
               ╰─ ⚠️ Cannot derive action 'response'; add @HarnessOperation with a HarnessInput payload, @HarnessIgnore, or compose an explicit descriptor
          case gesture(Double, Double)
               ┬──────────────────────
               ╰─ ⚠️ Action 'gesture' has multiple payloads; wrap them in a @HarnessSchema struct or add @HarnessIgnore
        }
      }
      """
    } expansion: {
      """
      struct Feature {
        struct State {}
        enum Action {
          case response(Result<String, Error>)
          case gesture(Double, Double)
        }

        @MainActor public static var harnessDescriptor: FeatureDescriptor<State, Action> {
          FeatureDescriptor<State, Action>("Feature", observation: { state in
              .object([:])
            })
        }
      }

      extension Feature: HarnessFeatureProvider {
      }
      """
    }
  }

  @Test func stringEnumSchema() {
    assertMacro {
      """
      @HarnessSchema
      enum Priority: String, Codable {
        case normal
        case urgent = "high"
      }
      """
    } expansion: {
      """
      enum Priority: String, Codable {
        case normal
        case urgent = "high"

        public static var harnessSchema: HarnessJSONSchema {
          .string(choices: ["normal", "high"])
        }
      }

      extension Priority: HarnessInput {
      }
      """
    }
  }

  @Test func invalidAttachment() {
    assertMacro {
      """
      @HarnessFeature
      enum Feature {}
      """
    } diagnostics: {
      """
      @HarnessFeature
      ╰─ 🛑 @HarnessFeature requires a struct with locally declared State and Action; use an explicit FeatureDescriptor for external types
      enum Feature {}
      """
    }
  }

  @Test func explicitOperation() {
    assertMacro {
      """
      @HarnessFeature
      struct Feature {
        struct State {}
        enum Action {
          @HarnessOperation("Rename item")
          case rename(String)
          @HarnessIgnore
          case response(Int)
        }
      }
      """
    } expansion: {
      """
      struct Feature {
        struct State {}
        enum Action {
          case rename(String)
          case response(Int)
        }

        @MainActor public static var harnessDescriptor: FeatureDescriptor<State, Action> {
          FeatureDescriptor<State, Action>("Feature", observation: { state in
              .object([:])
            })
          .valueOperation("rename", label: "Rename item", value: String.self, action: {
              .rename($0)
            })
        }
      }

      extension Feature: HarnessFeatureProvider {
      }
      """
    }
  }
}
#endif
