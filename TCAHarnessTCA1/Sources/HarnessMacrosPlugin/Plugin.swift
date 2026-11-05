import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct HarnessPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [HarnessFeatureMacro.self, HarnessSchemaMacro.self, MarkerMacro.self]
}
