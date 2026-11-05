import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct HarnessTCA2Plugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [HarnessFeatureMacro.self, HarnessSchemaMacro.self, MarkerMacro.self]
}
